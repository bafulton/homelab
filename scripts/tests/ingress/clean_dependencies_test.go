package ingress

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Argo packages the wrapper directly from a clean checkout. Prebuilding
// gateway-route's nested library archives can hide a missing direct dependency.
func TestBottleShipCleanDependencies(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	clean := t.TempDir()
	for _, rel := range []string{"charts", "kubernetes/apps/bottleship"} {
		source := filepath.Join(root, rel)
		err := filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() {
				if path != source && entry.Name() == "charts" {
					return filepath.SkipDir
				}
				return nil
			}
			if entry.Name() == "Chart.lock" || strings.HasSuffix(entry.Name(), ".tgz") {
				return nil
			}
			relative, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			destination := filepath.Join(clean, relative)
			if err := os.MkdirAll(filepath.Dir(destination), 0755); err != nil {
				return err
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			return os.WriteFile(destination, data, 0600)
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	chart := filepath.Join(clean, "kubernetes/apps/bottleship")
	// All BottleShip dependencies are file:// sources, so this needs no network.
	cmd := exec.Command("helm", "dependency", "update", chart, "--skip-refresh")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("clean dependency update: %v\n%s", err, out)
	}
	docs := renderChart(t, chart, "bottleship")
	findResource(t, docs, "ConfigMap", "bottleship-mdns-games")
	findResource(t, docs, "HTTPRoute", "bottleship-local-https")
}
