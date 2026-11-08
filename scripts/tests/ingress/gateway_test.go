package ingress

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestGatewayIsolation(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	for _, role := range []string{"admin", "apps"} {
		t.Run(role, func(t *testing.T) {
			name := "traefik-" + role
			docs := renderChart(t, filepath.Join(root, "kubernetes/infra", name), name)
			foundGateway, foundProxy := false, false
			var podLabels map[string]any
			for _, o := range docs {
				if o["kind"] == "CustomResourceDefinition" {
					t.Fatal("controller must not own CRDs")
				}
				if o["kind"] == "Deployment" {
					pod := o["spec"].(map[string]any)["template"].(map[string]any)
					podLabels = pod["metadata"].(map[string]any)["labels"].(map[string]any)
					ps := pod["spec"].(map[string]any)
					if ps["hostNetwork"] == true {
						t.Fatal("host networking enabled")
					}
					containers := ps["containers"].([]any)
					args := containers[0].(map[string]any)["args"].([]any)
					joined := ""
					for _, a := range args {
						joined += a.(string) + "\n"
					}
					for _, expected := range []string{"--providers.kubernetesgateway.labelSelector=homelab.io/ingress=" + role, "--providers.kubernetesgateway.gateways[0].name=" + name, "--providers.kubernetesgateway.gateways[0].namespace=" + name} {
						if !strings.Contains(joined, expected+"\n") {
							t.Fatalf("missing controller scope %s", expected)
						}
					}
					if strings.Contains(joined, "--providers.kubernetesingress") {
						t.Fatal("unwanted Ingress provider")
					}
					if role == "admin" && strings.Contains(joined, "--providers.kubernetescrd") {
						t.Fatal("admin CRD provider enabled")
					}
					if role == "apps" && !strings.Contains(joined, "--providers.kubernetescrd.ingressClass=traefik-apps") {
						t.Fatal("missing apps Middleware scope")
					}
				}
				if o["kind"] == "Gateway" {
					foundGateway = true
					if o["spec"].(map[string]any)["gatewayClassName"] != name {
						t.Fatal("wrong GatewayClass")
					}
				}
				if o["kind"] == "Service" {
					md, sp := o["metadata"].(map[string]any), o["spec"].(map[string]any)
					if sp["type"] == "LoadBalancer" && sp["allocateLoadBalancerNodePorts"] != false {
						t.Fatal("LoadBalancer allocates NodePorts")
					}
					if sp["type"] == "NodePort" {
						t.Fatal("NodePort Service")
					}
					if role == "apps" && md["name"] == "traefik-apps" && sp["type"] != "LoadBalancer" {
						t.Fatal("apps Gateway Service must be a LoadBalancer")
					}
					if sp["loadBalancerClass"] == "tailscale" {
						foundProxy = true
						if sp["allocateLoadBalancerNodePorts"] != false {
							t.Fatal("proxy allocates NodePorts")
						}
						ann := md["annotations"].(map[string]any)
						if ann["tailscale.com/tags"] != "tag:k8s-"+role {
							t.Fatal("wrong or overlapping proxy tags")
						}
						if role == "admin" {
							ports := sp["ports"].([]any)
							if len(ports) != 1 || ports[0].(map[string]any)["port"] != 443 {
								t.Fatal("admin must publish only 443")
							}
						}
					}
				}
			}
			if !foundGateway || !foundProxy || podLabels == nil {
				t.Fatal("missing Gateway/proxy/Deployment")
			}
			for _, o := range docs {
				if o["kind"] != "Service" {
					continue
				}
				for key, value := range o["spec"].(map[string]any)["selector"].(map[string]any) {
					if podLabels[key] != value {
						t.Fatalf("Service selects another controller: %v", o["metadata"])
					}
				}
			}
		})
	}
}
