# Goldpinger

Node-to-node connectivity and latency probes.

## Administrative access

The graph at `https://goldpinger.catfish-mountain.com` uses the shared
[admin gateway](../traefik-admin/README.md) and requires the Tailscale
`group:homelab-admins` grant. Its internal peer probes/metrics remain unchanged.
See [CAT-17 migration](../traefik/MIGRATION.md) for rollout and verification.
