# Tailnet split DNS

This CoreDNS deployment is exposed as `cluster-dns.catfish-mountain.ts.net` through
a Tailscale LoadBalancer Service. Configure its Tailscale IP as the restricted
nameserver for `catfish-mountain.com` in the tailnet DNS settings. It is separate
from Kubernetes' built-in `kube-dns` service.

Explicit administrative records (`argocd`, `longhorn`, `garage`, `signoz`,
`goldpinger`, `traefik-admin`, `traefik-apps`) point to `cluster-admin`. The zone
apex and wildcard point to `cluster-apps`. These are two shared proxy identities;
each application remains an ordinary Kubernetes backend.

Run `./scripts/update-ingress-dns.py --check` from the repository root to verify
that the committed records match the current Tailscale Service addresses. When a
proxy identity changes, regenerate the values with the helper, review the diff,
and sync CoreDNS through GitOps. The helper validates Service identity, tag and
address and only edits the local values file. Explicit A records avoid client
portability problems with [CNAMEs into MagicDNS](https://github.com/tailscale/tailscale/issues/7650).

DNS is not authorization. The admin proxy has only `tag:k8s-admin` and accepts
TCP 443 from `group:homelab-admins`; ordinary LAN clients cannot use the apps VIP
with an admin hostname. The DNS proxy retains `tag:k8s`, with TCP/UDP 53 grants
for tailnet members and cluster nodes. It does not acquire the admin tag. Keep
the DNS proxy's identity and exposure separate from the admin proxy.

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
