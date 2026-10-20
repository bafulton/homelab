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

Persistent volumes, all on the Longhorn `state` class - this data is
rebuildable, so it is snapshotted but not backed up:
- ClickHouse: 50Gi
- Zookeeper: 8Gi
- SigNoz DB: 1Gi

## Quiescing SigNoz

Three of the four workloads scale through `replicaCount: 0` in `values.yaml`.
ClickHouse does not: its StatefulSet belongs to
`ClickHouseInstallation/signoz-clickhouse`, and the operator ignores
`layout.replicasCount: 0`. Use the CHI's own switch instead:

```sh
kubectl patch chi signoz-clickhouse -n signoz --type merge -p '{"spec":{"stop":"yes"}}'
```

ArgoCD leaves that alone, because the chart renders no `stop` field and the
three-way diff ignores fields absent from both desired and last-applied state.
Remove it with a JSON-patch `remove` of `/spec/stop` to start back up.

Both Jobs in this app are hooks, and a hook that cannot finish blocks every
later sync - including the push that would fix it:

- `telemetrystore-migrator` needs ClickHouse up. Kept out of syncs via
  `telemetryStoreMigrator.upgradeHelmHooks: false`. (The key is
  `telemetryStoreMigrator`; `schemaMigrator` is not read by this chart and
  setting it does nothing.)
- `dashboard-sync` is a PostSync hook that waits on the SigNoz API, so it
  spins for its full timeout whenever the app is scaled down.

So scale **back up before the hook's retry budget runs out**, or clear the
wedged operation first - a corrective push alone will not land:

```sh
kubectl patch application signoz -n argocd --type json -p '[{"op":"remove","path":"/operation"}]'
```

## Email Notifications

SigNoz is configured to send alert notifications via Gmail SMTP. The app password is stored in Bitwarden Secrets Manager.

Environment variables are set on the SigNoz pod:
- `SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__SMARTHOST` - Gmail SMTP server
- `SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_SMTP__AUTH__PASSWORD` - From Kubernetes secret

To add notification channels, go to Settings → Alert Channels in the SigNoz UI.

### Email Subject Lines

Alertmanager's default email subject template prints bare label *values* with no
names, so alert mail arrives titled:

```
019e1d57-60c4-754a-a356-d22b2f0eba4b (Smart Home Device Offline http://localhost:8080/alerts/overview?ruleId=019e1d57-... warning gitops warning)
```

That is `<groupLabels> (<remaining commonLabels>)` — ruleId, then alertname,
ruleSource, severity, source and threshold.name. The two `warning`s are
`severity` and `threshold.name` saying the same thing.

The channels API accepts `email_configs[].headers`, and Alertmanager uses a
supplied `Subject` in place of its default template. `channels/email.json` sets
one, giving instead:

```
[WARNING] Smart Home Device Offline
[WARNING] Smart Home Device Offline x3     (3 entities in one group)
[RESOLVED] Smart Home Device Offline
```

**The SigNoz UI has no field for `headers`, so editing the Email channel in the
UI silently drops the Subject.** The sync job re-asserts it on every run, so a
UI save self-heals within 5 minutes.

Each `channels/<name>.json` is `{"name": <channel name>, "headers": {...}}`,
merged onto the channel's live receiver config so the HTML body template is
preserved. SigNoz fires a test notification on every channel PUT, so the sync
only PUTs when the live headers differ; if SigNoz ever stops retaining the
header, the job records that and stops retrying rather than emailing every
5 minutes.


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
2. Add `"preferredChannels": ["Email"]` — use the channel **name**, not its UUID
3. Add `"labels": {"source": "gitops"}` to identify GitOps-managed alerts
4. Add `"version": "v5"` (required by the SigNoz rules API)
5. Save to `alerts/<name>.json`
6. Commit and push - the PostSync Job will load it

### Removing an Alert

Delete the JSON file and push. The PostSync Job reconciles SigNoz against the
files in git: any rule with `labels.source == "gitops"` that isn't present in
git is deleted automatically. Manually-created rules (no `source: gitops` label)
are never touched.

### How It Works

1. An ArgoCD PostSync Job runs after each sync
2. The Job clones the repo and reads JSON files directly (avoids ConfigMap size limits)
3. For each dashboard/alert, it finds existing resources by title/name
4. If found, updates in place via PUT (preserves IDs and alert history)
5. If not found, creates via POST
6. After all upserts, reconciles: deletes any `source: gitops` rules not in git
7. Finally, merges any `channels/*.json` header overrides onto the matching
   notification channels (see [Email Subject Lines](#email-subject-lines))

### Forcing a PostSync Run

ArgoCD excludes hook resources (like the PostSync Job itself) from its diff
calculation. Changing only `dashboard-sync-job.yaml` produces no detectable diff,
so no sync is triggered and the new job never runs.

**Workaround:** bump `sync-script-version` in `templates/dashboard-checksum-configmap.yaml`.
This is a non-hook ConfigMap that ArgoCD _does_ diff, so incrementing the version
creates a synthetic change that triggers a sync → which then fires the PostSync job.

```yaml
# templates/dashboard-checksum-configmap.yaml
data:
  sync-script-version: "5"  # bump this when changing dashboard-sync-job.yaml
```
