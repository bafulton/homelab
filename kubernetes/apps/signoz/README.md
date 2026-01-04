# SigNoz

Open-source observability platform with metrics, logs, and traces in a single pane of glass.

## Access

Exposed via Tailscale at `https://signoz.<tailnet>.ts.net`

## Architecture

SigNoz deploys several components:

- **SigNoz Query Service** - UI and API server
- **ClickHouse** - Columnar database for telemetry storage
- **Zookeeper** - Coordination for ClickHouse
- **OTel Collector** - Receives telemetry data via OpenTelemetry protocol

## Sending Data to SigNoz

### From Kubernetes workloads

Configure your apps to send OpenTelemetry data to the collector:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://signoz-otel-collector.signoz:4317"
```

### Collector endpoints

| Protocol | Port | Endpoint |
|----------|------|----------|
| OTLP gRPC | 4317 | `signoz-otel-collector.signoz:4317` |
| OTLP HTTP | 4318 | `signoz-otel-collector.signoz:4318` |

## Storage

Data is stored in ClickHouse with default retention:
- Logs & Traces: 7 days
- Metrics: 30 days

Persistent volume: 20Gi (provisioned by Longhorn)
