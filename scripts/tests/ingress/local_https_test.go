package ingress

import (
	"encoding/json"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
)

func TestLANHTTPSBoundary(t *testing.T) {
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
	// TLS on :443 is published only on the LAN Service, never the edge/tailnet Service.
	for _, name := range []string{"traefik-apps", "traefik-apps-tailscale"} {
		svc := findResource(t, docs, "Service", name)
		has443 := false
		for _, raw := range spec(svc)["ports"].([]any) {
			port := raw.(map[string]any)
			if port["port"] == 443 {
				has443 = true
			}
		}
		if has443 != (name == "traefik-apps") {
			t.Fatalf("unexpected :443 exposure on %s", name)
		}
	}
}

func TestLocalRedirectsAndAuth(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	for _, tc := range []struct {
		app, route, host, listener, scheme string
		port                               int
	}{
		{"bottleship", "local-http", "games.local", "web", "https", 443},
		{"home-assistant", "local-https-to-http", "home.local", "home-local", "http", 80},
		{"jellyfin", "local-https-to-http", "media.local", "media-local", "http", 80},
	} {
		docs := renderChart(t, filepath.Join(root, "kubernetes/apps", tc.app), tc.app)
		route := findResource(t, docs, "HTTPRoute", tc.app+"-"+tc.route)
		if !reflect.DeepEqual(spec(route)["hostnames"], []any{tc.host}) {
			t.Fatal("redirect hostname widened")
		}
		parents := spec(route)["parentRefs"].([]any)
		if len(parents) != 1 || parents[0].(map[string]any)["sectionName"] != tc.listener {
			t.Fatal("wrong redirect entrance")
		}
		rules := spec(route)["rules"].([]any)
		if len(rules) != 1 {
			t.Fatal("unexpected redirect rules")
		}
		rule := rules[0].(map[string]any)
		if _, ok := rule["backendRefs"]; ok {
			t.Fatal("redirect must never forward to a backend")
		}
		filters := rule["filters"].([]any)
		redirect := filters[0].(map[string]any)["requestRedirect"].(map[string]any)
		// No path or hostname rewrite: Gateway API preserves the original path/query.
		if !reflect.DeepEqual(redirect, map[string]any{"scheme": tc.scheme, "port": tc.port, "statusCode": 302}) {
			t.Fatalf("wrong redirect: %v", redirect)
		}
	}
	docs := renderChart(t, filepath.Join(root, "kubernetes/apps/bottleship"), "bottleship")
	for _, tc := range []struct{ name, host, cookie string }{
		{"oauth2-proxy", "games.fultonhuffman.com", "_games_auth"},
		{"oauth2-proxy-local", "games.local", "_games_local_auth"},
	} {
		proxy := findResource(t, docs, "Deployment", tc.name)
		pod := spec(proxy)["template"].(map[string]any)["spec"].(map[string]any)
		container := pod["containers"].([]any)[0].(map[string]any)
		args := container["args"].([]any)
		for _, want := range []string{"--redirect-url=https://" + tc.host + "/oauth2/callback", "--cookie-secure=true", "--cookie-name=" + tc.cookie, "--code-challenge-method=S256"} {
			if !slices.Contains(args, any(want)) {
				t.Fatalf("%s missing %s", tc.name, want)
			}
		}
		if tc.name == "oauth2-proxy-local" && pod["nodeSelector"].(map[string]any)["homelab.io/location"] != "local" {
			t.Fatal("local sessions must run at home")
		}
		svc := findResource(t, docs, "Service", tc.name)
		if spec(svc)["selector"].(map[string]any)["app.kubernetes.io/name"] != tc.name {
			t.Fatal("proxy services overlap")
		}
	}
	local := findResource(t, docs, "HTTPRoute", "bottleship-local-https")
	rules := spec(local)["rules"].([]any)
	callback := rules[0].(map[string]any)
	if _, ok := callback["filters"]; ok {
		t.Fatal("callback must be reachable before authentication")
	}
	if callback["backendRefs"].([]any)[0].(map[string]any)["name"] != "oauth2-proxy-local" {
		t.Fatal("local callback went to public proxy")
	}
	app := rules[1].(map[string]any)
	auth := app["filters"].([]any)[0].(map[string]any)["extensionRef"].(map[string]any)
	if auth["name"] != "pocket-id-auth-local" {
		t.Fatal("local application lacks local authentication")
	}
	mdns := findResource(t, docs, "ConfigMap", "bottleship-mdns-games")
	var config map[string]any
	if err := json.Unmarshal([]byte(mdns["data"].(map[string]any)["config.json"].(string)), &config); err != nil {
		t.Fatal(err)
	}
	if config["hostname"] != "games" || config["ip"] != "192.168.1.200" || config["port"] != float64(443) {
		t.Fatalf("wrong games discovery: %v", config)
	}
}
