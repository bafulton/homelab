# Smartctl Exporter

Prometheus exporter for SMART disk health metrics.

## Why It's Needed

Monitors disk health for early warning before failure:
- NVMe SSDs (beelink)
- USB drives (beelink)
- SD cards (Raspberry Pis)

## Metrics Collected

- `smartctl_device_smart_status` - Overall health (1 = healthy)
- `smartctl_device_temperature` - Drive temperature
- `smartctl_device_power_on_seconds` - Total power-on time
- `smartctl_device_read_errors_total` - Read error count
- `smartctl_device_write_errors_total` - Write error count
- Various SMART attributes per device type

## Integration

Metrics are auto-discovered by signoz-k8s-infra via `prometheus.io/scrape` annotation.
