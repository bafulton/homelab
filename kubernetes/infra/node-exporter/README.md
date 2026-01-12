# Node Exporter

Prometheus node_exporter for hardware and OS metrics from each node.

## Metrics Collected

- **Temperature**: CPU/SoC temps via hwmon and thermal_zone
- **CPU**: Usage, info, frequency
- **Memory**: Usage, available, cached
- **Disk**: I/O, space usage
- **Network**: Interface traffic, errors
- **Pressure**: Linux PSI metrics (CPU/memory/IO pressure)
- **Processes**: Process count by state

## Integration

Metrics are auto-discovered by signoz-k8s-infra via `prometheus.io/scrape` annotation and displayed in the Node Temperature dashboard.
