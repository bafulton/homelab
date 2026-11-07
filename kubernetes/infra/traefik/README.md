# Ingress admission policies and legacy retirement

This Application now owns the admission policies for the ingress split. The
upstream controller dependency and old dashboard/certificate templates have been
removed from its desired manifests. **Because `prune: false` is retained, existing
legacy resources remain running until explicitly retired.**

The replacements are:

- [traefik-admin](../traefik-admin/README.md): one shared Tailscale-only proxy for
  authorized administrators and wholly administrative interfaces.
- [traefik-apps](../traefik-apps/README.md): household LAN and intentional public
  applications, including Cloudflare and OCI upstreams.

Follow [MIGRATION.md](MIGRATION.md) before merging or syncing. ApplicationSet
sync-wave annotations do not serialize independent Applications or wait for
certificates/proxy provisioning; this is a coordinated migration.

## Enforced boundaries

- Gateways have fixed namespace/name/class identities and approved listeners.
- All HTTPRoutes declare access and explicit Gateway/listener parents.
- Admin hostnames and backend namespaces cannot be published as app routes.
- The public Argo exception is limited to `POST /api/webhook`.
- Admin frontend/backend Services cannot acquire ordinary LoadBalancers,
  NodePorts or external IPs. Only the canonical tagged admin gateway may use a
  Tailscale LoadBalancer, on TCP 443 with no NodePorts.
- Admin ingress pods cannot use host networking or host ports.

These policies govern supported Gateway API ingress. They do not replace
Kubernetes RBAC, application authentication, or broader workload isolation.
The [regression suite](../../../scripts/tests/ingress/README.md) evaluates the
actual CEL against rendered manifests and adversarial changes.

Mixed-use application administration remains subject to its existing
application authorization.
