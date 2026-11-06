# Gateway routes

Shared Helm chart for explicitly classified HTTPRoutes and optional mDNS advertisements.
See [CAT-17 migration](../../kubernetes/infra/traefik/MIGRATION.md) before deploying the ingress split.

Every route needs `access: admin` or `access: apps` and explicit `parentRefs`, including
`sectionName`. There is no implicit/default Gateway attachment. The chart rejects
mismatched parents and admin mDNS advertisements; cluster admission additionally
checks hostnames, administrative namespaces and the Argo webhook exception.

```yaml
gateway-route:
  routes:
    - name: ui
      access: admin
      parentRefs:
        - name: traefik-admin
          namespace: traefik-admin
          sectionName: admin
      hostnames: [myapp.catfish-mountain.com]
      service:
        name: myapp-server
        port: 80
```

Household/public routes use `access: apps` and `traefik-apps` in namespace
`traefik-apps`. Add a parent for every required listener:

| Listener | Port | Purpose |
| --- | --- | --- |
| `web` | 80 | LAN HTTP and Cloudflare Tunnel upstream |
| `websecure` | 443 | Household HTTPS over LAN/Tailscale |
| `edge` | 8443 | OCI passthrough, `media.fultonhuffman.com` only |
| `edge-games` | 8443 | OCI passthrough, `games.fultonhuffman.com` only |

```yaml
gateway-route:
  routes:
    - name: household
      access: apps
      parentRefs:
        - name: traefik-apps
          namespace: traefik-apps
          sectionName: web
        - name: traefik-apps
          namespace: traefik-apps
          sectionName: websecure
      hostnames: [myapp.fultonhuffman.com, myapp.local]
      service:
        name: myapp-server
        port: 80
      mdns:
        name: My App
        ip: 192.168.1.200
```

Public apps and `.local` household services belong on apps ingress. Wholly
administrative routes use explicit names under `catfish-mountain.com`. Existing
application authentication remains required; network authorization does not log
users into applications. Home Assistant, Jellyfin and Pocket ID remain mixed-use
apps protected by their application roles/authentication.

`rules` accepts Gateway API HTTPRoute rules in place of the default `/` backend
rule. BottleShip uses this for ForwardAuth. Its Middleware is explicitly labeled
`homelab.io/ingress: apps` and annotated with ingress class `traefik-apps` to match
the scoped CRD provider. The Argo public hostname permits only `POST /api/webhook`.

Keep `gateway-route` as a `file://../../../charts/gateway-route` dependency at
version `1.0.0`. Run `helm dependency update`, rather than trusting old local
archives, whenever this shared chart changes. See [ingress validation](../../scripts/tests/ingress/README.md).
