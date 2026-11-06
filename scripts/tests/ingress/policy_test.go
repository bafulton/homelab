package ingress

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/cel-go/cel"
	"gopkg.in/yaml.v3"
)

func render(t *testing.T, chart, namespace string) []map[string]any {
	if filepath.Base(chart) == "traefik" {
		return renderChart(t, chart, namespace, "--show-only", "templates/public-listener-policy.yaml")
	}
	return renderChart(t, chart, namespace)
}

func clone(in map[string]any) map[string]any {
	data, _ := yaml.Marshal(in)
	var out map[string]any
	_ = yaml.Unmarshal(data, &out)
	return out
}
func spec(o map[string]any) map[string]any { return o["spec"].(map[string]any) }
func meta(o map[string]any) map[string]any { return o["metadata"].(map[string]any) }

// Kubernetes removes null optional fields before CEL evaluates the API object.
func removeNulls(value any) {
	switch v := value.(type) {
	case map[string]any:
		for key, child := range v {
			if child == nil {
				delete(v, key)
			} else {
				removeNulls(child)
			}
		}
	case []any:
		for _, child := range v {
			removeNulls(child)
		}
	}
}

// Evaluate the actual checked-in CEL, rather than a reimplementation of its rules.
func allowed(t *testing.T, policy, obj map[string]any) bool {
	t.Helper()
	obj = clone(obj)
	removeNulls(obj)
	env, err := cel.NewEnv(cel.Variable("object", cel.DynType), cel.Variable("variables", cel.DynType))
	if err != nil {
		t.Fatal(err)
	}
	vars := map[string]any{}
	eval := func(expression string) any {
		ast, issues := env.Compile(expression)
		if issues.Err() != nil {
			t.Fatalf("compile %s: %v", expression, issues.Err())
		}
		prog, err := env.Program(ast)
		if err != nil {
			t.Fatal(err)
		}
		val, _, err := prog.Eval(map[string]any{"object": obj, "variables": vars})
		if err != nil {
			return false
		} // admission failurePolicy: Fail
		return val.Value()
	}
	if raw, ok := spec(policy)["matchConditions"].([]any); ok {
		for _, condition := range raw {
			if eval(condition.(map[string]any)["expression"].(string)) != true {
				return true
			}
		}
	}
	if raw, ok := spec(policy)["variables"].([]any); ok {
		for _, v := range raw {
			item := v.(map[string]any)
			vars[item["name"].(string)] = eval(item["expression"].(string))
		}
	}
	for _, raw := range spec(policy)["validations"].([]any) {
		if eval(raw.(map[string]any)["expression"].(string)) != true {
			return false
		}
	}
	return true
}

func TestIngressBoundary(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	policies := map[string]map[string]any{}
	for _, p := range render(t, filepath.Join(root, "kubernetes/infra/traefik"), "traefik") {
		if p["kind"] == "ValidatingAdmissionPolicy" {
			policies[meta(p)["name"].(string)] = p
		}
	}
	var all []map[string]any
	paths, _ := filepath.Glob(filepath.Join(root, "kubernetes/*/*/values.yaml"))
	for _, values := range paths {
		data, _ := os.ReadFile(values)
		var v map[string]any
		if err := yaml.Unmarshal(data, &v); err != nil {
			t.Fatal(err)
		}
		if _, ok := v["gateway-route"]; !ok {
			continue
		}
		ns := filepath.Base(filepath.Dir(values))
		if custom, ok := v["namespace"].(string); ok {
			ns = custom
		}
		for _, o := range render(t, filepath.Dir(values), ns) {
			if _, ok := meta(o)["namespace"]; !ok {
				meta(o)["namespace"] = ns
			}
			all = append(all, o)
		}
	}
	var route, webhook, gateway, service, pod map[string]any
	for _, o := range all {
		switch o["kind"] {
		case "HTTPRoute":
			if !allowed(t, policies["httproute-access-boundary"], o) {
				t.Fatalf("valid route rejected: %v", meta(o))
			}
			if meta(o)["namespace"] == "longhorn" {
				route = o
			}
			if meta(o)["name"] == "argocd-webhook" {
				webhook = o
			}
		case "Gateway":
			if !allowed(t, policies["gateway-public-listeners-need-public-hostname"], o) {
				t.Fatalf("valid Gateway rejected: %v", meta(o))
			}
			if meta(o)["namespace"] == "traefik-admin" {
				gateway = o
			}
		case "Service":
			if _, exists := spec(o)["type"]; !exists {
				spec(o)["type"] = "ClusterIP"
			}
			if !allowed(t, policies["admin-ingress-no-lan-service"], o) {
				t.Fatalf("external admin backend Service: %v", meta(o))
			}
			if meta(o)["namespace"] == "traefik-admin" {
				if !allowed(t, policies["admin-ingress-no-lan-service"], o) {
					t.Fatalf("valid Service rejected: %v", meta(o))
				}
				if spec(o)["type"] == "LoadBalancer" {
					service = o
				}
			}
		case "Deployment":
			if meta(o)["namespace"] == "traefik-admin" {
				template := spec(o)["template"].(map[string]any)
				pod = map[string]any{"metadata": map[string]any{"namespace": "traefik-admin"}, "spec": template["spec"]}
				if !allowed(t, policies["admin-ingress-no-host-ports"], pod) {
					t.Fatal("valid admin pod rejected")
				}
			}
		case "CustomResourceDefinition":
			if meta(o)["namespace"] == "traefik-admin" || meta(o)["namespace"] == "traefik-apps" {
				t.Fatal("ingress must not own CRDs")
			}
		}
	}
	for label, fixture := range map[string]map[string]any{"route": route, "webhook": webhook, "gateway": gateway, "service": service, "pod": pod} {
		if fixture == nil {
			t.Fatalf("missing %s fixture", label)
		}
	}
	cases := []struct {
		name, policy string
		base         map[string]any
		mutate       func(map[string]any)
	}{
		{"admin route on apps", "httproute-access-boundary", route, func(o map[string]any) {
			spec(o)["parentRefs"] = []any{map[string]any{"name": "traefik-apps", "namespace": "traefik-apps", "sectionName": "web"}}
		}},
		{"admin mislabeled apps", "httproute-access-boundary", route, func(o map[string]any) {
			meta(o)["labels"] = map[string]any{"homelab.io/access": "apps"}
			spec(o)["hostnames"] = []any{"longhorn.fultonhuffman.com"}
			spec(o)["parentRefs"] = []any{map[string]any{"name": "traefik-apps", "namespace": "traefik-apps", "sectionName": "web"}}
		}},
		{"implicit listeners", "httproute-access-boundary", route, func(o map[string]any) { delete(spec(o)["parentRefs"].([]any)[0].(map[string]any), "sectionName") }},
		{"webhook catchall", "httproute-access-boundary", webhook, func(o map[string]any) {
			r := spec(o)["rules"].([]any)[0].(map[string]any)
			r["matches"] = []any{map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/"}}}
		}},
		{"admin HTTP listener", "gateway-public-listeners-need-public-hostname", gateway, func(o map[string]any) { spec(o)["listeners"].([]any)[0].(map[string]any)["protocol"] = "HTTP" }},
		{"LAN loadbalancer", "admin-ingress-no-lan-service", service, func(o map[string]any) { delete(spec(o), "loadBalancerClass") }},
		{"allocated node ports", "admin-ingress-no-lan-service", service, func(o map[string]any) { spec(o)["allocateLoadBalancerNodePorts"] = true }},
		{"external address", "admin-ingress-no-lan-service", service, func(o map[string]any) { spec(o)["externalIPs"] = []any{"192.168.1.203"} }},
		{"host networking", "admin-ingress-no-host-ports", pod, func(o map[string]any) { spec(o)["hostNetwork"] = true }},
		{"host port", "admin-ingress-no-host-ports", pod, func(o map[string]any) {
			spec(o)["containers"].([]any)[0].(map[string]any)["ports"] = []any{map[string]any{"containerPort": 443, "hostPort": 443}}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			obj := clone(tc.base)
			if !allowed(t, policies[tc.policy], obj) {
				t.Fatal("unmodified cloned fixture must be accepted")
			}
			tc.mutate(obj)
			if allowed(t, policies[tc.policy], obj) {
				t.Fatal("unsafe configuration accepted")
			}
		})
	}
	fmt.Printf("Validated %d rendered resources and %d negative admission cases\n", len(all), len(cases))
}

func TestEdgeHostnamePolicy(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	var policy, gateway map[string]any
	for _, o := range render(t, filepath.Join(root, "kubernetes/infra/traefik"), "traefik") {
		if o["kind"] == "ValidatingAdmissionPolicy" && meta(o)["name"] == "gateway-public-listeners-need-public-hostname" {
			policy = o
		}
	}
	for _, o := range render(t, filepath.Join(root, "kubernetes/infra/traefik-apps"), "traefik-apps") {
		if o["kind"] == "Gateway" {
			gateway = o
			meta(gateway)["namespace"] = "traefik-apps"
		}
	}
	if policy == nil || gateway == nil {
		t.Fatal("missing Gateway policy fixture")
	}
	if !allowed(t, policy, gateway) {
		t.Fatal("shared public edge rejected")
	}
	for _, hostname := range []string{"*", "*.com", "*.catfish-mountain.com", "media.fultonhuffman.com", ""} {
		t.Run(hostname, func(t *testing.T) {
			bad := clone(gateway)
			found := false
			for _, raw := range spec(bad)["listeners"].([]any) {
				listener := raw.(map[string]any)
				if listener["name"] == "edge" {
					found = true
					listener["hostname"] = hostname
				}
			}
			if !found {
				t.Fatal("missing edge listener")
			}
			if allowed(t, policy, bad) {
				t.Fatalf("unexpected edge hostname accepted: %q", hostname)
			}
		})
	}
}
