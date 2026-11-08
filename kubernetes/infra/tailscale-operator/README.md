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

All hostnames are under `catfish-mountain.ts.net`. Individual admin service names
use split DNS under `catfish-mountain.com` and resolve to `cluster-admin`; Traefik
selects the backend by Host/SNI.

## Tags and authorization

The operator itself uses `tag:k8s-operator`. In [the tailnet policy](../../../tailscale/policy.hujson),
that tag owns the proxy tags so it can provision them. Tag ownership does not
itself grant network access. Service annotations explicitly set the
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
## Credentials and lifecycle

Bitwarden supplies the existing OAuth credentials through External Secrets.
`operatorConfig.defaultTags` identifies the operator, not individual application
backends. Verify OAuth/tag ownership permits the new proxy tags before deployment.
No new OAuth credentials are introduced by the split.

Proxy pods are named `ts-<service>-<hash>-0` in namespace `tailscale`. Inspect
Service status and tailnet machine tags after provisioning. A Tailscale frontend
does not remove ordinary LAN or NodePort paths; inspect generated Services too.
