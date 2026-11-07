# Ingress admission policies

This Application owns the cluster-wide Gateway API ingress admission policies.
It does not run a Traefik controller. The `traefik-admin` and `traefik-apps`
Applications run the two controllers; `traefik-crds` owns their CRDs.

The replacements are:

- [traefik-admin](../traefik-admin/README.md): one shared Tailscale-only proxy for
  authorized administrators and wholly administrative interfaces.
- [traefik-apps](../traefik-apps/README.md): household LAN and intentional public
  applications, including Cloudflare and OCI upstreams.

The policy Application stays separate from either controller so shared
admission rules have one owner independent of controller lifecycle.

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
