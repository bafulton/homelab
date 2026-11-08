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
	// The foundation permits these listeners but does not expose them yet.
	for _, host := range []string{"games", "home", "media"} {
		spec(gateway)["listeners"] = append(spec(gateway)["listeners"].([]any), map[string]any{
			"name": host + "-local", "port": 443, "protocol": "HTTPS", "hostname": host + ".local",
			"allowedRoutes": map[string]any{"namespaces": map[string]any{"from": "All"}, "kinds": []any{map[string]any{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute"}}},
			"tls":           map[string]any{"mode": "Terminate", "certificateRefs": []any{map[string]any{"name": "household-local-tls"}}},
		})
	}
	if !allowed(t, policy, gateway) {
		t.Fatal("permitted exact-host LAN listener rejected")
	}

	if !reflect.DeepEqual(spec(cert)["dnsNames"], []any{"games.local", "home.local", "media.local"}) {
		t.Fatalf("unexpected LAN certificate SANs: %v", spec(cert))
	}
	issuer := spec(cert)["issuerRef"].(map[string]any)
	if issuer["name"] != "homelab-ca" || issuer["kind"] != "ClusterIssuer" {
		t.Fatal("LAN certificate must use the existing private CA")
	}
	for _, name := range []string{"games-local", "home-local", "media-local"} {
		var listener map[string]any
		for _, raw := range spec(gateway)["listeners"].([]any) {
			l := raw.(map[string]any)
			if l["name"] == name {
				listener = l
			}
		}
		if listener == nil {
			t.Fatalf("missing %s listener", name)
		}
		tls := listener["tls"].(map[string]any)
		if listener["port"] != 443 || listener["protocol"] != "HTTPS" || tls["mode"] != "Terminate" ||
			!reflect.DeepEqual(tls["certificateRefs"], []any{map[string]any{"name": "household-local-tls"}}) {
			t.Fatalf("wrong LAN TLS configuration: %v", listener)
		}
		for _, hostname := range []string{"*.local", "*.catfish-mountain.com", "games.fultonhuffman.com", "unlisted.local", ""} {
			t.Run(name+" rejects "+hostname, func(t *testing.T) {
				bad := clone(gateway)
				for _, raw := range spec(bad)["listeners"].([]any) {
					l := raw.(map[string]any)
					if l["name"] == name {
						l["hostname"] = hostname
					}
				}
				if allowed(t, policy, bad) {
					t.Fatal("broadened LAN listener accepted")
				}
			})
		}
		route := map[string]any{
			"metadata": map[string]any{"namespace": "bottleship", "labels": map[string]any{"homelab.io/access": "apps"}},
			"spec": map[string]any{
				"parentRefs": []any{map[string]any{"name": "traefik-apps", "namespace": "traefik-apps", "sectionName": name}},
				"hostnames":  []any{listener["hostname"]},
				"rules":      []any{map[string]any{"backendRefs": []any{map[string]any{"name": "example", "port": 80}}}},
			},
		}
		if !allowed(t, routePolicy, route) {
			t.Fatal("exact-host LAN route rejected")
		}
		for _, h := range []string{"argocd.catfish-mountain.com", "games.fultonhuffman.com", "other.local"} {
			bad := clone(route)
			spec(bad)["hostnames"] = []any{h}
			if allowed(t, routePolicy, bad) {
				t.Fatalf("%s accepted on %s", h, name)
			}
		}
		bad := clone(route)
		spec(bad)["hostnames"] = []any{listener["hostname"], "other.local"}
		if allowed(t, routePolicy, bad) {
			t.Fatal("multi-host LAN HTTPS route accepted")
		}
	}
}
