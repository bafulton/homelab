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
		{"legacy attachment", `routes: [{name: invalid, access: admin, parentRefs: [{name: traefik, namespace: traefik, sectionName: websecure}], hostnames: [invalid.catfish-mountain.com]}]`},
		{"missing access", `routes: [{name: invalid, hostnames: [invalid.local]}]`},
		{"missing parents", `routes: [{name: invalid, access: admin, hostnames: [invalid.catfish-mountain.com]}]`},
		{"admin on apps", `routes: [{name: invalid, access: admin, parentRefs: [{name: traefik-apps, namespace: traefik-apps, sectionName: web}], hostnames: [invalid.catfish-mountain.com]}]`},
		{"missing listener", `routes: [{name: invalid, access: apps, parentRefs: [{name: traefik-apps, namespace: traefik-apps}], hostnames: [invalid.local]}]`},
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
