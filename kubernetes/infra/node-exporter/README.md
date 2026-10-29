# Node Exporter

Prometheus node_exporter for hardware and OS metrics from each node.

## Metrics Collected

Only what SigNoz's own host metrics don't already cover:

- **Temperature**: CPU/SoC temps via hwmon and thermal_zone (Node Temperature
  dashboard, High Node Temperature alert)
- **Pressure**: Linux PSI metrics (CPU/memory/IO pressure)
- **Processes**: process and thread counts by state

Every other collector is off (`--collector.disable-defaults`). CPU, memory,
disk, filesystem and network come from SigNoz's hostmetrics receiver
(`signoz-k8s-infra`). Enable a collector here again only for something that
receiver lacks.

## Integration

Metrics are auto-discovered by signoz-k8s-infra via `prometheus.io/scrape` annotation and displayed in the Node Temperature dashboard.
