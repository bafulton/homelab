package ingress

import (
	"path/filepath"
	"reflect"
	"testing"
)

func findResource(t *testing.T, docs []map[string]any, kind, name string) map[string]any {
	t.Helper()
	for _, o := range docs {
		if o["kind"] == kind && meta(o)["name"] == name {
			return o
		}
	}
	t.Fatalf("missing %s %s", kind, name)
	return nil
}

func TestLANHTTPSAdmission(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	docs := renderChart(t, filepath.Join(root, "kubernetes/infra/traefik-apps"), "traefik-apps")
	policies := renderChart(t, filepath.Join(root, "kubernetes/infra/gateway-policies"), "gateway-policies")
	policy := findResource(t, policies, "ValidatingAdmissionPolicy", "gateway-public-listeners-need-public-hostname")
	routePolicy := findResource(t, policies, "ValidatingAdmissionPolicy", "httproute-access-boundary")
	gateway := findResource(t, docs, "Gateway", "traefik-apps")
	cert := findResource(t, docs, "Certificate", "household-local")
	if !reflect.DeepEqual(spec(cert)["dnsNames"], []any{"games.local", "home.local", "media.local"}) {
		t.Fatalf("unexpected LAN certificate SANs: %v", spec(cert))
	}
	issuer := spec(cert)["issuerRef"].(map[string]any)
	if issuer["name"] != "homelab-ca" || issuer["kind"] != "ClusterIssuer" {
		t.Fatal("LAN certificate must use existing private CA")
	}

	// Model the permitted listener before activation, or use its deployed form
	// in the dependent PR. Never duplicate a listener from the rendered Gateway.
	var local map[string]any
	for _, raw := range spec(gateway)["listeners"].([]any) {
		if raw.(map[string]any)["name"] == "local" {
			local = raw.(map[string]any)
		}
	}
	if local == nil {
		local = map[string]any{
			"name": "local", "port": 443, "protocol": "HTTPS", "hostname": "*.local",
			"allowedRoutes": map[string]any{"namespaces": map[string]any{"from": "All"}, "kinds": []any{map[string]any{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute"}}},
			"tls":           map[string]any{"mode": "Terminate", "certificateRefs": []any{map[string]any{"name": "household-local-tls"}}},
		}
		spec(gateway)["listeners"] = append(spec(gateway)["listeners"].([]any), local)
	}
	if !allowed(t, policy, gateway) {
		t.Fatal("shared local listener rejected")
	}
	for _, tc := range []struct {
		field string
		value any
	}{
		{"hostname", "*"}, {"hostname", "*.com"}, {"hostname", "*.catfish-mountain.com"},
		{"hostname", "*.fultonhuffman.com"}, {"hostname", ""}, {"protocol", "HTTP"}, {"port", 8443},
	} {
		t.Run(tc.field+" boundary", func(t *testing.T) {
			bad := clone(gateway)
			for _, raw := range spec(bad)["listeners"].([]any) {
				l := raw.(map[string]any)
				if l["name"] == "local" {
					l[tc.field] = tc.value
				}
			}
			if allowed(t, policy, bad) {
				t.Fatalf("unsafe local listener accepted: %s=%v", tc.field, tc.value)
			}
		})
	}
	route := map[string]any{
		"metadata": map[string]any{"namespace": "bottleship", "labels": map[string]any{"homelab.io/access": "apps"}},
		"spec": map[string]any{
			"parentRefs": []any{map[string]any{"name": "traefik-apps", "namespace": "traefik-apps", "sectionName": "local"}},
			"hostnames":  []any{"games.local"},
			"rules":      []any{map[string]any{"backendRefs": []any{map[string]any{"name": "example", "port": 80}}}},
		},
	}
	// Hostname selection belongs to each route, not a shared app allowlist.
	for _, hostnames := range [][]any{{"games.local"}, {"home.local"}, {"media.local"}, {"another.local"}, {"games.local", "another.local"}} {
		good := clone(route)
		spec(good)["hostnames"] = hostnames
		if !allowed(t, routePolicy, good) {
			t.Fatalf("explicit local route rejected: %v", hostnames)
		}
	}
	for _, hostnames := range [][]any{{}, {"*.local"}, {"argocd.catfish-mountain.com"}, {"games.fultonhuffman.com"}, {"games.local", "games.fultonhuffman.com"}} {
		bad := clone(route)
		spec(bad)["hostnames"] = hostnames
		if allowed(t, routePolicy, bad) {
			t.Fatalf("unsafe LAN route accepted: %v", hostnames)
		}
	}
	bad := clone(route)
	meta(bad)["labels"] = map[string]any{"homelab.io/access": "admin"}
	if allowed(t, routePolicy, bad) {
		t.Fatal("admin route accepted on local listener")
	}
	bad = clone(route)
	meta(bad)["namespace"] = "argocd"
	if allowed(t, routePolicy, bad) {
		t.Fatal("administrative namespace published a local apps route")
	}
}
