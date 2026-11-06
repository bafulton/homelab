# Household and public ingress

Traefik controller for household LAN access and intentional public applications.
It replaces the old shared gateway's application traffic. Wholly administrative
UIs attach to [traefik-admin](../traefik-admin), including this controller's own
dashboard at `https://traefik.catfish-mountain.com`.

**Migration prerequisite:** follow [the coordinated rollout](../traefik/MIGRATION.md).
This README describes the intended configuration, not rollout status.

## Entrances

| Entrance | Destination | Listeners |
| --- | --- | --- |
| Household LAN/mDNS | MetalLB `192.168.1.200` | `web` 80, `websecure` 443 |
| Cloudflare Tunnel | `traefik-apps.traefik-apps.svc.cluster.local:80` | `web` |
| Tailnet household clients | `cluster-apps.catfish-mountain.ts.net` | 80, 443 |
| OCI edge forwarder (`tag:edge`) | `cluster-apps.catfish-mountain.ts.net:8443` | `edge`, `edge-games` |

Both LoadBalancers explicitly disable NodePort allocation. Port 8443 is published
only on the Tailscale Service. The OCI listeners retain exact hostname restrictions
for `media.fultonhuffman.com` and `games.fultonhuffman.com`; a public SNI plus an
administrative Host header must not reach any dashboard.

Home Assistant, Jellyfin, Pocket ID, BottleShip, yak-shave and the Argo webhook
use this gateway. Home Assistant/Jellyfin/Pocket ID mix household/public and admin
capabilities; their existing application authorization remains the boundary.
Only `POST /api/webhook` is admitted on Argo's public webhook hostname.

## Controller scope and middleware

The Gateway provider is scoped to `traefik-apps` in namespace `traefik-apps` and
GatewayClass selector `homelab.io/ingress=apps`. The ordinary Ingress provider is
disabled. The CRD provider remains enabled for BottleShip's ForwardAuth Middleware,
filtered by `homelab.io/ingress=apps` and ingress class `traefik-apps`. Middleware
resources need both that label and `kubernetes.io/ingress.class: traefik-apps`.
Do not introduce unscoped IngressRoutes as an alternate route mechanism.

Every [gateway-route](../../../charts/gateway-route/README.md) declares `access`
and explicit listener parents. Admission rejects admin attachment to this Gateway,
including routes in administrative backend namespaces. The two dashboards use
ClusterIP backend Services and admin-class routes.

Certificates are owned here for `*.catfish-mountain.com`,
`media.fultonhuffman.com`, and `games.fultonhuffman.com`. Other public TLS normally
terminates at Cloudflare. The single `traefik-crds` app continues to own CRDs;
this app sets `skipCrds: true`. Scheduling remains redundant across nodes with a
preference for local nodes; OCI remains a scheduling target.

## Verification

```sh
kubectl -n traefik-apps get deployment,svc,gateway,httproute,certificate
kubectl get gatewayclass traefik-apps
```

Confirm the LAN Service owns `.200`, neither Service has NodePorts, both OCI
certificates are Ready, the Gateway is Programmed, and BottleShip's Middleware
resolves. Test household discovery/control, Jellyfin streaming/seek, OIDC sign-in,
BottleShip callbacks and a real GitHub webhook delivery. Test public access with
conflicting Host/SNI and check that administrative responses never appear.

Use `helm dependency update` before trusting a local render. First render with `--include-crds` to audit bundled CRDs. To mirror Argo's
`skipCrds: true`, omit `--include-crds` (it overrides `--skip-crds` in template).
