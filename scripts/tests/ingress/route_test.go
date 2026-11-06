package ingress

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

func documents(t *testing.T, data []byte) []map[string]any {
	t.Helper()
	dec := yaml.NewDecoder(bytes.NewReader(data))
	var docs []map[string]any
	for {
		var doc map[string]any
		err := dec.Decode(&doc)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if doc != nil {
			docs = append(docs, doc)
		}
	}
	return docs
}

func renderChart(t *testing.T, chart, namespace string, extra ...string) []map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(chart, "values.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var v map[string]any
	if err := yaml.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	args := []string{"template", filepath.Base(chart), chart, "--namespace", namespace}
	// Argo omits --include-crds when skipCrds is true. Passing both flags
	// to Helm template still includes crds/, even with --skip-crds.
	if v["skipCrds"] == true {
		args = append(args, "--skip-crds")
	} else {
		args = append(args, "--include-crds")
	}
	args = append(args, extra...)
	var stderr bytes.Buffer
	cmd := exec.Command("helm", args...)
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("helm %s: %v\n%s", chart, err, stderr.String())
	}
	return documents(t, out)
}

func TestRouteContract(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	paths, _ := filepath.Glob(filepath.Join(root, "kubernetes/*/*/values.yaml"))
	count := 0
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
		for _, o := range renderChart(t, filepath.Dir(values), ns) {
			if o["kind"] != "HTTPRoute" {
				continue
			}
			count++
			metadata := o["metadata"].(map[string]any)
			labels := metadata["labels"].(map[string]any)
			if labels["homelab.io/access"] != "admin" && labels["homelab.io/access"] != "apps" {
				t.Fatalf("unclassified route: %v", metadata)
			}
			spec := o["spec"].(map[string]any)
			parents, ok := spec["parentRefs"].([]any)
			if !ok || len(parents) == 0 {
				t.Fatalf("missing explicit parents: %v", metadata)
			}
			for _, raw := range parents {
				p := raw.(map[string]any)
				for _, field := range []string{"name", "namespace", "sectionName"} {
					if p[field] == nil || p[field] == "" {
						t.Fatalf("missing %s in %v", field, metadata)
					}
				}
			}
		}
	}
	if count < 10 {
		t.Fatalf("expected full route inventory, got %d", count)
	}
	t.Logf("Validated explicit access/parents on %d routes", count)
}

func TestRejectInvalidRouteContract(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	for _, tc := range []struct{ name, contents string }{
		{"legacy mapping", `gateways: {admin: {name: traefik, namespace: traefik, listeners: [websecure]}}
routes: [{name: invalid, access: admin, hostnames: [invalid.catfish-mountain.com], service: {name: example, port: 80}}]`},
		{"missing access", `routes: [{name: invalid, hostnames: [invalid.local], service: {name: example, port: 80}}]`},
		{"unknown access", `routes: [{name: invalid, access: other, hostnames: [invalid.local], service: {name: example, port: 80}}]`},
		{"raw parentRefs", `routes: [{name: invalid, access: apps, parentRefs: [{name: traefik-apps}], hostnames: [invalid.local], service: {name: example, port: 80}}]`},
		{"admin listener override", `routes: [{name: invalid, access: admin, listeners: [web], hostnames: [invalid.local], service: {name: example, port: 80}}]`},
		{"apps websecure listener override", `routes: [{name: invalid, access: apps, listeners: [websecure], hostnames: [invalid.local], service: {name: example, port: 80}}]`},
		{"unknown listener", `routes: [{name: invalid, access: apps, listeners: [other], hostnames: [invalid.local], service: {name: example, port: 80}}]`},
		{"empty listeners", `routes: [{name: invalid, access: apps, listeners: [], hostnames: [invalid.local], service: {name: example, port: 80}}]`},
		{"duplicate listeners", `routes: [{name: invalid, access: apps, listeners: [web, web], hostnames: [invalid.local], service: {name: example, port: 80}}]`},
		{"admin mDNS", `routes: [{name: invalid, access: admin, mdns: {name: Example, ip: 192.168.1.200}, hostnames: [invalid.local], service: {name: example, port: 80}}]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "values.yaml")
			if err := os.WriteFile(file, []byte(tc.contents), 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("helm", "template", "invalid", filepath.Join(root, "charts/gateway-route"), "-f", file)
			if out, err := cmd.CombinedOutput(); err == nil {
				t.Fatalf("unsafe route rendered: %s", out)
			} else if !bytes.Contains(out, []byte("gateway-route:")) {
				t.Fatalf("unexpected Helm failure: %s", out)
			}
		})
	}
}

func TestAccessProfiles(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	for _, tc := range []struct {
		name, access, override string
		listeners              []string
	}{
		{"admin defaults", "admin", "", []string{"admin"}},
		{"apps defaults", "apps", "", []string{"web"}},
		{"media override", "apps", "listeners: [web, edge]", []string{"web", "edge"}},
		{"games only", "apps", "listeners: [edge]", []string{"edge"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "values.yaml")
			contents := "routes:\n  - name: example\n    access: " + tc.access + "\n    " + tc.override + "\n    hostnames: [example.local]\n    service: {name: example, port: 80}\n"
			if err := os.WriteFile(file, []byte(contents), 0600); err != nil {
				t.Fatal(err)
			}
			docs := renderChart(t, filepath.Join(root, "charts/gateway-route"), "example", "-f", file)
			found := false
			for _, o := range docs {
				if o["kind"] != "HTTPRoute" {
					continue
				}
				found = true
				parents := o["spec"].(map[string]any)["parentRefs"].([]any)
				if len(parents) != len(tc.listeners) {
					t.Fatalf("wrong listener count: %v", parents)
				}
				for i, raw := range parents {
					p := raw.(map[string]any)
					if p["name"] != "traefik-"+tc.access || p["namespace"] != "traefik-"+tc.access || p["sectionName"] != tc.listeners[i] {
						t.Fatalf("wrong generated parent: %v", p)
					}
				}
			}
			if !found {
				t.Fatal("missing generated route")
			}
		})
	}
}

func TestGatewayKindsAreExplicit(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	for _, chart := range []string{"traefik-admin", "traefik-apps"} {
		t.Run(chart, func(t *testing.T) {
			docs := renderChart(t, filepath.Join(root, "kubernetes/infra", chart), chart)
			found := false
			for _, o := range docs {
				if o["kind"] != "Gateway" {
					continue
				}
				found = true
				listeners := o["spec"].(map[string]any)["listeners"].([]any)
				for _, raw := range listeners {
					listener := raw.(map[string]any)
					kinds := listener["allowedRoutes"].(map[string]any)["kinds"].([]any)
					if len(kinds) != 1 {
						t.Fatalf("listener %s must allow exactly HTTPRoute: %v", listener["name"], kinds)
					}
					kind := kinds[0].(map[string]any)
					if kind["group"] != "gateway.networking.k8s.io" || kind["kind"] != "HTTPRoute" {
						t.Fatalf("listener %s has unexpected route kind: %v", listener["name"], kind)
					}
				}
			}
			if !found {
				t.Fatal("Gateway not rendered")
			}
		})
	}
}
