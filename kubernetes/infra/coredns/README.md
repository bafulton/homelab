# Tailnet split DNS

This CoreDNS deployment is exposed as `cluster-dns.catfish-mountain.ts.net` through
a Tailscale LoadBalancer Service. Configure its Tailscale IP as the restricted
nameserver for `catfish-mountain.com` in the tailnet DNS settings. It is separate
from Kubernetes' built-in `kube-dns` service.

After the [ingress migration](../traefik/MIGRATION.md), explicit administrative
records (`argocd`, `longhorn`, `garage`, `signoz`, `goldpinger`, `traefik`,
`traefik-admin`) point to the assigned `cluster-admin` Tailscale IP. The zone apex
and wildcard point to `cluster-apps`. These are two shared proxy identities;
each dashboard is still an ordinary Kubernetes backend.

The branch retains the existing zone until the replacement Services are
provisioned. Before DNS cutover, run `./scripts/update-ingress-dns.py` from the
repository root, review/commit its values diff, and sync CoreDNS. The helper reads
Service status and rejects missing, unexpected or non-Tailscale addresses/tags;
it does not mutate the cluster. Verify actual machine tags separately. Rerun it
after proxy recreation. Explicit A records avoid the known client portability
problems with [CNAMEs into MagicDNS](https://github.com/tailscale/tailscale/issues/7650).

DNS is not authorization. The admin proxy has only `tag:k8s-admin` and accepts
TCP 443 from `group:homelab-admins`; ordinary LAN clients cannot use the apps VIP
with an admin hostname. The DNS proxy retains `tag:k8s` during migration, with
TCP/UDP 53 grants for tailnet members and cluster nodes. It does not acquire the
admin tag. The existing Tailscale Service's NodePorts should be reviewed separately
if changing DNS exposure; this migration does not recreate this identity.

## Proxy PodSecurity

Operator proxy pods run in namespace `tailscale`, which requires privileged
PodSecurity for interface/sysctl/forwarding setup. This existing namespace setting
is retained:

```sh
kubectl label namespace tailscale pod-security.kubernetes.io/enforce=privileged --overwrite
```

## Verification

From a Tailscale client, resolve each dashboard and confirm its final address is
the **admin** proxy, then test authorized/unauthorized connections separately.
Check DNS over both UDP and TCP 53. Verify public `argocd-webhook` resolution and
GitHub delivery remain functional; external DNS is managed by Cloudflare.
