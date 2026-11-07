# Household and public ingress

Traefik controller for household LAN access and intentional public applications.
Wholly administrative UIs attach to [traefik-admin](../traefik-admin), including
this controller's own dashboard at `https://traefik-apps.catfish-mountain.com`.

## Entrances

| Entrance | Destination | Listeners |
| --- | --- | --- |
| Household LAN/mDNS | MetalLB `192.168.1.200` | `web` 80 |
| Cloudflare Tunnel | `traefik-apps.traefik-apps.svc.cluster.local:80` | `web` |
| Tailnet household clients | `cluster-apps.catfish-mountain.ts.net` | 80 |
| OCI edge forwarder (`tag:edge`) | `cluster-apps.catfish-mountain.ts.net:8443` | `edge` |

Both LoadBalancers explicitly disable NodePort allocation. Port 8443 is published
only on the Tailscale Service. The shared OCI listener is restricted to `*.fultonhuffman.com`, and the forwarder
retains an exact media/games SNI allowlist; a public SNI plus an
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
HTTPRoute is the only supported route API. The CRD provider remains enabled for
BottleShip's Middleware, while cluster-wide admission rejects
`IngressRoute`, `IngressRouteTCP`, and `IngressRouteUDP` resources. Apps routes
may target only Services in their own namespace, including RequestMirror
destinations.

Every [gateway-route](../../../charts/gateway-route/README.md) declares `access`;
the chart generates its explicit Gateway/listener parents. Only apps needing
special entrances specify `listeners`. Admission rejects admin attachment to this Gateway,
including routes in administrative backend namespaces. The two dashboards use
ClusterIP backend Services and admin-class routes.

Certificates are owned here for `media.fultonhuffman.com` and
`games.fultonhuffman.com`, used only by the shared OCI listener. Public TLS for
other application hostnames terminates at Cloudflare; private admin TLS belongs
to `traefik-admin`. The single `traefik-crds` app continues to own CRDs;
this app sets `skipCrds: true`. Scheduling remains redundant across nodes with a
preference for local nodes; OCI remains a scheduling target.

## Verification

```sh
kubectl -n traefik-apps get deployment,svc,gateway,httproute,certificate
kubectl get gatewayclass traefik-apps
```

Confirm the apps Service owns `.200` without NodePorts, both OCI certificates are
Ready, the Gateway is Programmed, and BottleShip's Middleware resolves. Household
and public routes use this Gateway; administrative routes do not.

Use `helm dependency update` before trusting a local render. First render with `--include-crds` to audit bundled CRDs. To mirror Argo's
`skipCrds: true`, omit `--include-crds` (it overrides `--skip-crds` in template).
