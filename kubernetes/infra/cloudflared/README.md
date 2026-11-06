# cloudflared

Outbound Cloudflare Tunnel for intentional public applications. The tunnel goes
to `http://traefik-apps.traefik-apps.svc.cluster.local:80`, then classified Gateway
API routes select the backend. It never targets the admin gateway.

The [CAT-17 migration](../traefik/MIGRATION.md) coordinates this upstream change;
this README describes the target configuration, not a completed rollout.

## Configuration and public names

Tunnel ingress and DNS are managed by [opentofu/cloudflare](../../../opentofu/cloudflare/README.md),
not manually in the dashboard. The module's `domains` map defines:

- `wildcard_public: true` for `fultonhuffman.com`, `yak-shave.com`, and `benfulton.me`.
- `wildcard_public: false` for `catfish-mountain.com`, with the explicit public
  exception `argocd-webhook`.
- A final 404 for all other tunnel hostnames.

The public Argo HTTPRoute additionally restricts access to `POST /api/webhook`.
Administrative UIs attach only to [traefik-admin](../traefik-admin/README.md) and
require an administrator Tailscale grant; supplying an admin Host header through
this tunnel cannot select an administrative route on apps ingress.

Public media/games names use the OCI edge forwarder and its hostname-restricted
8443 listeners, rather than sending their bulk traffic through the tunnel.
Home Assistant, Jellyfin and Pocket ID retain their application authorization.

## Adding a public route

For a wildcard-public domain, use an `access: apps` route with explicit parent
`traefik-apps` / namespace `traefik-apps` / listener `web` (plus any other needed
listeners). For a private-domain exception, update the module's domain
`public_subdomains` set too and apply the reviewed OpenTofu plan. See the
[shared route examples](../../../charts/gateway-route/README.md).

Public TLS normally terminates at Cloudflare. The upstream from cloudflared to
the apps Service is HTTP. Application authentication is still required where
configured; Cloudflare Tunnel by itself does not authenticate users.

## Deployment and monitoring

This chart runs two cloudflared replicas. The existing Bitwarden-managed token is
synced into `tunnel-credentials`. Metrics on port 2000 are scraped by OTel, including
`cloudflared_tunnel_ha_connections`, `cloudflared_tunnel_total_requests`, and
`cloudflared_tunnel_request_errors`.

```sh
kubectl -n cloudflared logs -l app=cloudflared -f
```

The Cloudflare dashboard can be used to inspect tunnel health. Keep configuration
changes in OpenTofu so DNS and routing remain reviewable.
