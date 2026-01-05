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

## Dashboards & Alerts as Code

Dashboards and alerts can be managed as JSON files in this chart and automatically loaded via the SigNoz API on each sync.

### Adding a Dashboard

1. Export the dashboard JSON from SigNoz UI (Dashboards → ... → Export)
2. Save to `dashboards/<name>.json`
3. Commit and push - the PostSync Job will load it

### Adding an Alert

1. Create the alert in SigNoz UI first to get the JSON structure
2. Save to `alerts/<name>.json`
3. Commit and push - the PostSync Job will load it

### API Endpoints

| Resource | Method | Endpoint |
|----------|--------|----------|
| Dashboards | POST | `/api/v1/dashboards` |
| Alerts | POST | `/api/v1/rules` |

Authentication via `SIGNOZ-API-KEY` header (token stored in Bitwarden).

### How It Works

1. An ArgoCD PostSync Job runs after each sync
2. The Job clones the repo and reads JSON files directly (avoids ConfigMap size limits)
3. For each file, it finds existing resources by title/name and deletes them
4. Then creates fresh resources from the JSON files

This ensures Git is the source of truth - changes in the repo replace what's in SigNoz.
