package ingress

import (
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestSharedEdgeListener(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	found := 0
	for _, name := range []string{"traefik", "traefik-apps"} {
		chart := filepath.Join(root, "kubernetes/infra", name)
		data, err := os.ReadFile(filepath.Join(chart, "values.yaml"))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		var values map[string]any
		if err := yaml.Unmarshal(data, &values); err != nil {
			t.Fatal(err)
		}
		if _, active := values["traefik"]; !active {
			continue
		} // retired policy-only wrapper
		for _, o := range renderChart(t, chart, name) {
			if o["kind"] != "Gateway" {
				continue
			}
			found++
			edges := 0
			for _, raw := range o["spec"].(map[string]any)["listeners"].([]any) {
				listener := raw.(map[string]any)
				if listener["port"] != 8443 {
					continue
				}
				edges++
				if listener["name"] != "edge" || listener["hostname"] != "*.fultonhuffman.com" || listener["protocol"] != "HTTPS" {
					t.Fatalf("unsafe shared edge: %v", listener)
				}
				tls := listener["tls"].(map[string]any)
				if tls["mode"] != "Terminate" {
					t.Fatal("edge must terminate cluster TLS")
				}
				refs := tls["certificateRefs"].([]any)
				names := map[any]bool{}
				for _, r := range refs {
					names[r.(map[string]any)["name"]] = true
				}
				if len(refs) != 2 || !names["media-fultonhuffman-com-tls"] || !names["games-fultonhuffman-com-tls"] {
					t.Fatalf("missing edge certificates: %v", refs)
				}
			}
			if edges != 1 {
				t.Fatalf("expected one shared edge listener, got %d", edges)
			}
		}
	}
	if found == 0 {
		t.Fatal("no application Gateway rendered")
	}
}
