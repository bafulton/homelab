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
preserved. The sync only PUTs when the live headers differ, so a steady state
is a no-op; and if SigNoz ever stops retaining the header, the job records that
and stops retrying instead of rewriting it every 5 minutes. (A raw API PUT to
/api/v1/channels sends no test notification - that is the UI/MCP path only.)

#### Why the sync service account holds signoz-admin

Deliberate, not an oversight. Reviewed 2026-10-20.

Exactly one call in the sync needs it: the channel `PUT`. Dashboards (full
CRUD), alert rules (full CRUD including the reconcile deletes) and channel
*reads* all work under `signoz-editor`, which is what the account held until
the Subject override was added. `signoz-editor` gets `403 only admins can
access this resource` on `PUT /api/v1/channels`, and v2 is the same -
`PUT /api/v2/notification_channels/{id}` is also admin-only.

The clean fix would be a custom role granted `notification-channel:update`
alone. That permission exists, but custom roles require an active SigNoz
license and this is the community build, so it is not available here. SigNoz
also documents fine-grained access control as beta, and its IAM overview does
not list notification channels among the resources it covers yet - so even
with a license it is not certain the permission is grantable today.

Accepted trade-off: the token can delete dashboards, alert rules and channels,
not just upsert them, and the 5-minute CronJob mounts it. Revisit if this ever
gets an Enterprise license, or if SigNoz makes channel permissions grantable
without one. The alternatives considered and rejected were dropping channel
reconciliation from automation (loses the self-heal when a UI save wipes the
Subject) and splitting it into a second CronJob with its own admin key (keeps
an admin key anyway, for less code).


## Alerts

Infrastructure alerts are defined in `alerts/*.json`:

| Alert | Severity | Threshold | Metric |
|-------|----------|-----------|--------|
| High Memory Usage | warning | >95% | k8s.node.memory.working_set / allocatable |
| High CPU Usage | warning | >90% | k8s.node.cpu.usage / allocatable |
| High Disk Usage | warning | >85% | longhorn_disk_usage_bytes / capacity |
| Node Not Ready | critical | != Ready | k8s.node.condition |
| Certificate Expiring Soon | warning | <7 days | certmanager_certificate_expiration_timestamp_seconds |

GitOps-managed alerts have the label `source: gitops`.

**Severity convention.** With one notification channel and no routing policy,
severity only sets the email subject prefix (`[CRITICAL]` / `[WARNING]`), so it
is an inbox triage signal:

- `critical` — something is broken *now*: a node not Ready, a service with no
  replicas, a drive out of spare blocks or past its rated endurance.
- `warning` — heading toward broken: resource pressure, wear trending up, a
  certificate expiring, a peripheral offline. Resource thresholds are warnings
  because `Node Not Ready` is the critical backstop if one actually tips over.

`Disk SMART Health Failing` is currently a `warning` even though "disk may be
dying" arguably reads as critical. Left as-is rather than changed in passing.

Re-notification is off on every rule — the first email is the to-do item.

## Dashboards & Alerts as Code

Dashboards and alerts are managed as JSON files and automatically synced via the SigNoz API.

### Adding a Dashboard

1. Export the dashboard JSON from SigNoz UI (Dashboards → ... → Export)
2. Save to `dashboards/<name>.json`
3. Commit and push - the PostSync Job will load it

### Adding an Alert

Prefer the `signoz-alerts` chart (`charts/signoz-alerts`) — it emits all of the
below from a handful of values. Hand-written JSON in `alerts/` is for rules the
chart cannot express.

Rules use the **v2alpha1** schema. The v1 shape (top-level `evalWindow`,
`frequency`, `preferredChannels`, and `condition.op`/`target`/`matchType`) is
rejected by `/api/v2/rules`.

1. Create the alert in SigNoz UI first to get the query structure
2. Add `"schemaVersion": "v2alpha1"`
3. Put the threshold and channel inside `condition.thresholds` — the threshold
   `name` is the severity tier (`critical`, `error`, `warning`, `info`) and
   doubles as the routing label, and `channels` takes the channel **name**, not
   its UUID:

   ```json
   "condition": {
     "compositeQuery": { "...": "..." },
     "selectedQueryName": "A",
     "thresholds": {
       "kind": "basic",
       "spec": [{
         "name": "warning", "target": 85,
         "op": "above", "matchType": "at_least_once",
         "channels": ["Email"]
       }]
     }
   }
   ```

   `op` is `above`/`below`/`equal`/`not_equal`/`above_or_equal`/`below_or_equal`/
   `outside_bounds`; `matchType` is `at_least_once`/`all_the_times`/`on_average`/
   `in_total`/`last`.
4. Add `"labels": {"source": "gitops", "severity": "warning"}`. `source`
   identifies GitOps-managed alerts (the reconciler only deletes those). Keep
   `severity` equal to the threshold `name` — the email Subject template reads
   `.CommonLabels.severity`, so dropping it degrades subjects to `[FIRING]`.
   Drop it only if the rule grows a second threshold.
5. Add `"evaluation": {"kind": "rolling", "spec": {"evalWindow": "5m0s", "frequency": "1m0s"}}`.
   Both are required — v1's implicit 5m/1m defaults are gone.
6. Add `"notificationSettings": {"renotify": {"enabled": false}, "usePolicy": false}`.
   Required by the schema. Re-notification is deliberately off everywhere here:
   the first email is the to-do item and a 4h reminder is just noise. (v1
   re-notified every 4h implicitly, so this is a change from the old behaviour.)
7. Save to `alerts/<name>.json`
8. Commit and push - the PostSync Job will load it

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
