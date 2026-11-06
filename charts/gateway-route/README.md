# Gateway routes

Shared Helm chart for HTTPRoutes and optional mDNS advertisements. Applications
choose an access class; the chart generates explicit Kubernetes Gateway references.
See [the migration stages](../../kubernetes/infra/traefik/MIGRATION.md).

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
household/public entrance and normally uses both `web` and `websecure` listeners.
Gateway names, namespaces, and default listeners live centrally in this chart's
`gateways` mapping. Ordinary app values do not repeat them.

## Listener overrides

Apps that need a different set of entrances can specify `listeners`. This replaces
the default list. The existing OCI services use:

```yaml
# Jellyfin: LAN/ordinary HTTPS plus the public media passthrough listener.
access: apps
listeners: [web, websecure, edge-media]

# BottleShip: LAN/ordinary HTTPS plus the public games passthrough listener.
access: apps
listeners: [web, websecure, edge-games]
```

| Listener | Port | Purpose |
| --- | --- | --- |
| `web` | 80 | LAN HTTP and Cloudflare Tunnel upstream |
| `websecure` | 443 | Household HTTPS over LAN/Tailscale |
| `edge-media` | 8443 | OCI passthrough, `media.fultonhuffman.com` only |
| `edge-games` | 8443 | OCI passthrough, `games.fultonhuffman.com` only |

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

The generated HTTPRoute uses native Gateway API `parentRefs`: `name` identifies
the Gateway, `namespace` locates it, and `sectionName` selects a listener. These
are output fields rather than the application-facing values interface.

## Migration mapping

Stages 1/2 centrally map both access classes to the scoped legacy `traefik` Gateway,
retaining current entrances. Stage 2's two new ingress wrappers override only the
admin mapping to expose their dashboards through the new admin Gateway. These
are infrastructure-owned provisioning overrides, not repeated app configuration.
Stage 3 changes the shared mapping to the dedicated gateways and removes those
overrides. Strict admission then checks generated attachments and the public
webhook exception. Classification alone does not enforce isolation before cutover.

Keep the `file://../../../charts/gateway-route` dependency at version `1.0.0`.
Run `helm dependency update` whenever this shared chart changes; old local archives
can hide updated defaults/templates. See [validation](../../scripts/tests/ingress/README.md).
