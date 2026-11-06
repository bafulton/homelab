# Ingress boundary regression checks

Requires Helm, Go and Python with PyYAML. Run from any directory:

```sh
./scripts/validate-ingress.sh
```

The script refreshes all affected chart dependencies using an isolated Helm
repository configuration. It deliberately uses `helm dependency update` so tests
do not rely on stale shared-chart or upstream archives. No Chart.lock or archives
are committed. For an already refreshed checkout, run `go -C scripts/tests/ingress test -count=1 -v ./...`.

Tests render every classified application, both controllers, and the ingress
admission policies, respecting each app's `skipCrds` setting. They cover access-profile defaults and optional listener overrides, then evaluate the
actual policy CEL with cel-go against valid manifests and adversarial mutations.
The test harness uses dynamic CEL objects; Kubernetes server-side dry runs are
also required to check API schemas, and live policy status must show no type
warnings before enabling bindings. These tests do not prove live routing, DNS,
Tailscale authorization or enforcement from ordinary LAN clients. See the
[migration runbook](../../../kubernetes/infra/traefik/MIGRATION.md) for that matrix.
