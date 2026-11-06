# Ingress routing checks

Requires Helm, Go, Python and PyYAML. Run `./scripts/validate-ingress.sh` to refresh
affected chart dependencies and test every rendered HTTPRoute's classification and
explicit Gateway/listener attachment, plus rejection of invalid chart inputs.
Use `go -C scripts/tests/ingress test -count=1 -v ./...` after dependencies are fresh.

The first migration stage retains explicit legacy attachment. These checks do
not claim administrative isolation; the cutover PR adds admission-policy CEL
regression tests and live validation requirements. See the
[migration stages](../../../kubernetes/infra/traefik/MIGRATION.md).
