# Tailscale Kubernetes Operator

The operator creates tailnet proxy devices for Kubernetes Services using
`type: LoadBalancer` and `loadBalancerClass: tailscale`. Most HTTP applications
share Traefik gateways rather than having individual Tailscale machines.

## Managed identities

| Proxy hostname | Kubernetes Service | Tags |
| --- | --- | --- |
| `cluster-admin` | `traefik-admin/traefik-admin` | `tag:k8s-admin` only |
| `cluster-apps` | `traefik-apps/traefik-apps-tailscale` | `tag:k8s-apps` only |
| `cluster-dns` | `coredns/coredns-tailscale` | existing `tag:k8s` |
| `cluster-gateway` (legacy) | `traefik/traefik-tailscale` | existing `tag:k8s`, removed at retirement |

All hostnames are under `catfish-mountain.ts.net`. The new gateways are the
[CAT-17 target topology](../traefik/MIGRATION.md); verify rollout status in the
cluster. Individual admin hostnames resolve through split DNS to `cluster-admin`,
then Traefik selects the backend by Host/SNI.

## Tags and authorization

The operator itself uses `tag:k8s-operator`. In [the tailnet policy](../../../tailscale/policy.hujson),
that tag owns the proxy tags so it can provision them. Tag ownership does not
itself grant network access. New Service annotations explicitly override the
operator's default proxy tag:

```yaml
metadata:
  annotations:
    tailscale.com/hostname: cluster-admin
    tailscale.com/tags: tag:k8s-admin
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  allocateLoadBalancerNodePorts: false
```

Only the homelab administrator group can reach admin TCP 443. Tailnet members may
use household apps on 80/443 and DNS on TCP/UDP 53; the OCI edge gets apps TCP 8443
only. Do not add `tag:k8s` to the admin proxy. Proxy tags are set at provisioning;
changing an existing Service annotation does not reliably retag an existing
identity—see [upstream tag documentation](https://tailscale.com/docs/kubernetes-operator/reference/tags).
The migration uses new Service/proxy identities deliberately.

## Credentials and lifecycle

Bitwarden supplies the existing OAuth credentials through External Secrets.
`operatorConfig.defaultTags` identifies the operator, not individual application
backends. Verify OAuth/tag ownership permits the new proxy tags before deployment.
No new OAuth credentials are introduced by the split.

Proxy pods are named `ts-<service>-<hash>-0` in namespace `tailscale`. Inspect
Service status and the tailnet machine tags after provisioning. Do not assume a
Tailscale frontend removes ordinary LAN/NodePort paths: inspect generated Services
and use the [acceptance matrix](../traefik/MIGRATION.md).
