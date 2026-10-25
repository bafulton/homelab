# signoz-k8s-infra

Kubernetes infrastructure monitoring for SignOz. Deploys two kinds of OTel collector: a DaemonSet (`otel-agent`) for per-node host, kubelet and log data, and a Deployment (`otel-deployment`) for cluster metrics, events and Prometheus scraping. Both forward to the existing SignOz installation.

## What It Collects

| Source | Description |
|--------|-------------|
| Host Metrics | CPU, memory, disk, network per node |
| Kubelet Metrics | Pod/container resource usage |
| Cluster Metrics | Node conditions, allocatable resources |
| Kubernetes Events | Cluster events visible in SignOz |
| Container Logs | Logs from all pods |
| Other app metrics | See "Adding Scrape Targets" below |

## What's Disabled

- **Tracing** - Disabled to reduce overhead

## Adding Scrape Targets

Apps with `prometheus.io/*` annotations on their pods are auto-discovered. Add these annotations to your app's metrics service:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "9090"
prometheus.io/path: "/metrics"  # optional, defaults to /metrics
```

For targets that annotations can't describe, such as ones that need credentials, add a job to `presets.prometheus.scrapeConfigs` in values.yaml. The chart appends these to the annotation job in the same `prometheus/scraper` receiver, so the annotation job keeps working:

```yaml
k8s-infra:
  presets:
    prometheus:
      scrapeConfigs:
        - job_name: my-app
          scrape_interval: 60s
          static_configs:
            - targets:
                - my-service.my-namespace:9090
```

Scraping runs in the `otel-deployment` collector (a single Deployment, not the per-node DaemonSet), so any credential files mount there, via `otelDeployment.extraVolumes` and `otelDeployment.extraVolumeMounts`.

### Home Assistant

Home Assistant's `/api/prometheus` requires authentication, so it is scraped by the `home-assistant` job in `scrapeConfigs` rather than by annotations. That job sends a long-lived access token belonging to HA's non-admin `metrics` user:

- The token lives in Bitwarden and reaches the collector through the `home-assistant-metrics-token` ExternalSecret, mounted at `/secrets/home-assistant/token`.
- `credentials_file` is re-read on every scrape, so rotating the token in Bitwarden takes effect after the ExternalSecret refresh, with no restart.
- Keep "Can only log in from the local network" **off** for the `metrics` user. The collector can run on the remote node, whose requests reach HA from a Tailscale address (`100.64.0.0/10`). HA counts only private ranges as local, so it rejects the token from there with a 401.
