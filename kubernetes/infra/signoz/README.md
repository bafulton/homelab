# SigNoz

Open-source observability platform with metrics, logs, and traces in a single pane of glass.

## Access

`https://signoz.catfish-mountain.com` (requires Tailscale connection)

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

Persistent volumes (on Longhorn nvme):
- ClickHouse: 50Gi
- Zookeeper: 8Gi
- SigNoz DB: 1Gi

## Email Notifications

SigNoz is configured to send alert notifications via Gmail SMTP. The app password is stored in Bitwarden Secrets Manager.

Environment variables are set on the SigNoz pod:
- `SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__SMARTHOST` - Gmail SMTP server
- `SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD` - From Kubernetes secret

To add notification channels, go to Settings → Alert Channels in the SigNoz UI.

## Alerts

Infrastructure alerts are defined in `alerts/*.json`:

| Alert | Severity | Threshold | Metric |
|-------|----------|-----------|--------|
| High Memory Usage | critical | >85% | k8s.node.memory.working_set / allocatable |
| High CPU Usage | critical | >90% | k8s.node.cpu.usage / allocatable |
| High Disk Usage | critical | >85% | longhorn_disk_usage_bytes / capacity |
| Node Not Ready | critical | != Ready | k8s.node.condition |
| Certificate Expiring Soon | warning | <7 days | certmanager_certificate_expiration_timestamp_seconds |

GitOps-managed alerts have the label `source: gitops`.

## Dashboards & Alerts as Code

Dashboards and alerts are managed as JSON files and automatically synced via the SigNoz API.

### Adding a Dashboard

1. Export the dashboard JSON from SigNoz UI (Dashboards → ... → Export)
2. Save to `dashboards/<name>.json`
3. Commit and push - the PostSync Job will load it

### Adding an Alert

1. Create the alert in SigNoz UI first to get the JSON structure
2. Add `"preferredChannels": ["<channel-id>"]` with your notification channel ID
3. Add `"labels": {"source": "gitops"}` to identify GitOps-managed alerts
4. Save to `alerts/<name>.json`
5. Commit and push - the PostSync Job will load it

### How It Works

1. An ArgoCD PostSync Job runs after each sync
2. The Job clones the repo and reads JSON files directly (avoids ConfigMap size limits)
3. For each file, it finds existing resources by title/name
4. If found, updates in place via PUT (preserves IDs and alert history)
5. If not found, creates new resource via POST

This ensures Git is the source of truth while preserving resource IDs for stable links and alert history.
