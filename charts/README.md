# Shared Helm Charts

Reusable Helm charts used as dependencies by apps in `kubernetes/infra/` and `kubernetes/apps/`.

## Charts

| Chart | Description |
|-------|-------------|
| [bitwarden-secret](./bitwarden-secret/) | Creates ExternalSecrets that pull from Bitwarden |
| [longhorn-storage](./longhorn-storage/) | Creates Longhorn PVCs with optional recurring snapshots |
| [mdns-config](./mdns-config/) | Advertises services via mDNS (Bonjour/Zeroconf) |
| [signoz-alerts](./signoz-alerts/) | Creates SigNoz alerts via ConfigMap discovery |
| [tailscale-ingress](./tailscale-ingress/) | Creates Tailscale Ingress and optional Service resources |
| [traefik-ingress](./traefik-ingress/) | Creates Traefik IngressRoutes for LAN access |

## Usage

Reference these charts as dependencies in your app's `Chart.yaml`:

```yaml
dependencies:
  - name: <chart-name>
    version: 1.0.0
    repository: file://../../../charts/<chart-name>
```

See each chart's README for configuration details.
