# Gateway routes

Shared Helm chart for HTTPRoutes and optional mDNS advertisements. Applications
choose an access class; the chart generates explicit Kubernetes Gateway references.
See the [admin gateway](../../kubernetes/infra/traefik-admin/README.md) and
[apps gateway](../../kubernetes/infra/traefik-apps/README.md) for their current
listeners and access boundaries.

```yaml
gateway-route:
  routes:
    - name: ui
      access: admin
      hostnames: [myapp.catfish-mountain.com]
      service:
        name: myapp-server
        port: 80
```

`access: admin` selects the administrative entrance. `access: apps` selects the
household/public entrance and normally uses the `web` listener. The apps Gateway
does not terminate HTTPS for household/public routes; Cloudflare terminates public
TLS, while the OCI forwarder has its own shared TLS listener.
Gateway names, namespaces, and default listeners live centrally in this chart's
`gateways` mapping. Ordinary app values do not repeat them.

## Listener overrides

Apps that need a different set of entrances can specify `listeners`. This replaces
the default list. The existing OCI services use:

```yaml
# Jellyfin and BottleShip: household HTTP plus the shared OCI TLS entrance.
access: apps
listeners: [web, edge]
```

| Listener | Port | Purpose |
| --- | --- | --- |
| `web` | 80 | LAN HTTP and Cloudflare Tunnel upstream |
| `edge` | 8443 | OCI TLS passthrough; shared listener restricted to `*.fultonhuffman.com` |

The shared `edge` listener is one entrance for OCI-forwarded public traffic. Only
routes selecting `edge` can use it; the forwarder still accepts only media/games
SNI. Both existing certificates must be Ready; a bad reference can affect both
apps. Public SNI and Host may select different public apps within this shared
listener; application authentication still applies.

Admin listeners are controlled by the central mapping, with no per-route override.
The chart rejects missing/unknown access classes, raw `parentRefs`, invalid/empty
listener overrides, duplicate listeners, and administrative mDNS advertisements.

## Household discovery and custom rules

```yaml
gateway-route:
  routes:
    - name: household
      access: apps
      hostnames: [myapp.fultonhuffman.com, myapp.local]
      service:
        name: myapp-server
        port: 80
      mdns:
        name: My App
        ip: 192.168.1.200
```

`rules` supplies Gateway API HTTPRoute rules instead of the default `/` backend.
BottleShip uses this for ForwardAuth; the Argo public webhook uses an exact
`POST /api/webhook` match. Existing application authentication remains required.

The generated HTTPRoute uses the Gateway API's standard `parentRefs` fields:
`name` is the referenced Gateway object's name, `namespace` tells Kubernetes
where to find that object, and `sectionName` names one of its
`spec.listeners[].name` values. The name and namespace often match by convention,
as they do for these Gateways, but identify different parts of the reference.
`sectionName` is the API field name; it selects a Gateway listener, rather than
an arbitrary application-defined label. These fields are generated output, not
part of the app-facing values interface.

## Gateway mapping

`admin` maps to `traefik-admin/traefik-admin` on its `admin` listener. Its Tailscale
Service is tagged `tag:k8s-admin`; only `group:homelab-admins` can connect on TCP
443. `apps` maps to `traefik-apps/traefik-apps` on `web`. The apps Gateway serves
the LAN VIP and Cloudflare Tunnel upstream; its shared `edge` listener is reserved
for OCI-forwarded public hostnames. `gateway-route` generates each HTTPRoute's
explicit parent references from this mapping.

Cluster-wide admission policies enforce the route and Service boundaries. They are
owned by the policy Application documented at
[`kubernetes/infra/gateway-policies`](../../kubernetes/infra/gateway-policies/README.md).

Keep the `file://../../../charts/gateway-route` dependency at version `1.0.0`.
Run `helm dependency update` whenever this shared chart changes; old local archives
can hide updated defaults/templates. See [validation](../../scripts/tests/ingress/README.md).
