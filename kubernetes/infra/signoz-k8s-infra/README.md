# signoz-k8s-infra

Kubernetes infrastructure monitoring for SignOz. Deploys OTel collectors as a DaemonSet to collect cluster-wide metrics and forward them to the existing SignOz installation.

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

For apps that don't support annotations, add static scrape configs in values.yaml:

```yaml
presets:
  prometheus:
    scrapeConfigs:
      - job_name: my-app
        scrape_interval: 30s
        static_configs:
          - targets:
              - my-service.my-namespace:9090
```
