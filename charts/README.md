# Shared Helm Charts

Reusable Helm charts used as dependencies by apps in `kubernetes/infra/` and `kubernetes/apps/`.

## Charts

| Chart | Description |
|-------|-------------|
| [tailscale-ingress](./tailscale-ingress/) | Creates Tailscale Ingress and optional Service resources |

## Usage

Reference these charts as dependencies in your app's `Chart.yaml`:

```yaml
dependencies:
  - name: <chart-name>
    version: 1.0.0
    repository: file://../../../charts/<chart-name>
    condition: <chart-name>.enabled
```

See each chart's README for configuration details.
