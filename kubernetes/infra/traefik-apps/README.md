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
this app sets `skipCrds: true`. Both replicas require
`homelab.io/location=local`. The existing hostname topology spread constraint
spreads each revision across eligible home nodes; `pod-template-hash` keeps
surge pods from competing with the old revision's spread. Rolling updates keep
both existing replicas available and allow one surge pod. The existing
`homelab.io/prefer-off` toleration permits scheduling on the home nodes.

## Household placement and rollout

The household application path must stay on the home LAN: mDNS advertisement →
MetalLB `192.168.1.200` → this controller → Home Assistant, Jellyfin, or BottleShip.
BottleShip's oauth2-proxy also requires home placement for session checks. Any
separate local-session proxy added for `games.local` (CAT-23) must carry the same
selector and toleration. Public Pocket ID login remains an accepted internet
dependency; this does not promise fully local authentication or whole-cluster
WAN-outage survival.

Existing required placement is preserved: mDNS, MetalLB LAN speakers, and Home
Assistant select `homelab.io/location=local`; Jellyfin and BottleShip are pinned
to `beelink` for their local media/bundle volumes. The
[subnet-route-steering DaemonSet](../subnet-route-steering) stays enabled on every
home node. Its priority-5260 rules direct the home LAN and peer home pod CIDRs
to `main`, ahead of Tailscale table 52, so Flannel can use the bare LAN between
home nodes. CAT-24 verifies actual traffic and mDNS resolution.

Home-node capacity was checked separately before this change. General workloads
retain their existing scheduling eligibility. Private CoreDNS, Tailscale proxies
and operator, traefik-admin, and Pocket ID are outside this placement change.

Merge the placement commit through GitOps and let ArgoCD sync `traefik-apps` and
`bottleship`. No manual apply or restart is needed. Watch the two rollouts:

```sh
kubectl -n traefik-apps rollout status deployment/traefik-apps --timeout=180s
kubectl -n bottleship rollout status deployment/oauth2-proxy --timeout=180s
kubectl get nodes -L homelab.io/location
kubectl -n traefik-apps get pods -o wide
kubectl -n bottleship get pods -o wide
kubectl -n traefik-apps get endpointslices -l kubernetes.io/service-name=traefik-apps -o yaml
kubectl -n bottleship get endpointslices -l kubernetes.io/service-name=oauth2-proxy -o yaml
kubectl -n kube-system get daemonset,pods -l app.kubernetes.io/name=subnet-route-steering -o wide
```

Confirm two ready Traefik replicas spread across home nodes, a ready home-node
proxy, ready Service endpoints on home nodes, and a ready steering pod on each
home node. Recheck the existing local backends, mDNS and MetalLB speakers. Verify
public routes and the administrative boundary using the ingress checks below
and CAT-24's client-side checks. The change to oauth2-proxy's pod template rolls
that proxy; BottleShip's game server and in-memory relay rooms are unaffected.

For rollback, revert the placement commit on `main`, push, and let ArgoCD sync
both apps. Wait for both rollouts and ready endpoints again. This restores the
previous preferred Traefik placement and unconstrained oauth2-proxy scheduling,
so the mandatory home-placement guarantee is withdrawn. Leave existing backend
placement and subnet-route-steering enabled. Use the Git revert rather than
`kubectl rollout undo`, which ArgoCD would overwrite.

## Verification

```sh
./scripts/validate-ingress.sh
kubectl -n traefik-apps get deployment,svc,gateway,httproute,certificate
kubectl get gatewayclass traefik-apps
```

Confirm the apps Service owns `.200` without NodePorts, both OCI certificates are
Ready, the Gateway is Programmed, and BottleShip's Middleware resolves. Household
and public routes use this Gateway; administrative routes do not.

Use `helm dependency update` before trusting a local render. First render with `--include-crds` to audit bundled CRDs. To mirror Argo's
`skipCrds: true`, omit `--include-crds` (it overrides `--skip-crds` in template).
