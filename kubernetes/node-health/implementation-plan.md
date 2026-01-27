# Implementation Plan: External Node Health Monitoring & SigNoz Alerts Chart

## Overview

Two components to implement:
1. **`node-health`** - External dead man's switch via healthchecks.io (DaemonSet)
2. **`signoz-alerts`** - Shared chart for declarative SigNoz alert configuration (ConfigMap discovery)

---

## Part 1: node-health Infra App

### Purpose
Detect node/cluster outages by sending heartbeats to external service (healthchecks.io). If heartbeats stop, get email alerts.

### Files to Create

```
kubernetes/infra/node-health/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── namespace.yaml
    └── daemonset.yaml
```

### Chart.yaml
- No upstream chart dependency (custom DaemonSet)
- Include `bitwarden-secret` chart for ping key secret

### values.yaml
```yaml
namespace: node-health

image:
  repository: alpine
  tag: "3.21"

healthchecks:
  pingUrl: https://hc-ping.com
  interval: 120        # 2 minutes
  timeout: 10
  includeBody: true    # Send node info in ping

bitwarden-secret:
  enabled: true
  secrets:
    - name: healthchecks-ping-key
      data:
        ping-key: "<bitwarden-secret-id>"  # User fills in
```

### DaemonSet Design
- **Container**: Alpine + curl in a loop
- **Node name**: Via Downward API (`spec.nodeName`)
- **Ping URL**: `https://hc-ping.com/<ping-key>/<node-name>` (auto-creates checks)
- **Tolerations**: Run on ALL nodes including control plane
- **Resources**: Minimal (10m CPU, 16Mi memory)
- **Retry**: Single retry with 30s delay on failure
- **PodSecurity**: baseline (no privileged access needed)

### User Setup Required
1. Create healthchecks.io account (free tier)
2. Get project ping key from Project Settings
3. Store ping key in Bitwarden Secrets Manager
4. Add Bitwarden secret ID to values.yaml
5. Configure healthchecks.io grace period (~5 min) and email notifications

---

## Part 2: signoz-alerts Shared Chart

### Purpose
Allow apps to declaratively define SigNoz alerts in their values.yaml. Alerts sync automatically via PostSync job.

### Files to Create

```
charts/signoz-alerts/
├── Chart.yaml
├── README.md
├── values.yaml
└── templates/
    ├── _helpers.tpl
    └── configmap.yaml
```

### Pattern (matches mdns-config)
- Apps include chart as dependency with `condition: signoz-alerts.enabled`
- Chart generates labeled ConfigMaps: `signoz.homelab.io/alert: "true"`
- Modified PostSync job discovers ConfigMaps across namespaces

### values.yaml Schema
```yaml
enabled: true

defaults:
  severity: warning
  evalWindow: 5m0s
  frequency: 1m0s
  notificationChannel: "019b9170-7e71-7dde-89c5-2c637c0d8646"

alerts:
  # Simple threshold
  - name: High Temperature
    type: threshold
    metric: node_hwmon_temp_celsius
    op: ">"
    threshold: 85
    groupBy: [instance]

  # Ratio (percentage)
  - name: High Memory
    type: ratio
    metrics:
      numerator: k8s.node.memory.working_set
      denominator: k8s.node.allocatable_memory
    multiply: 100
    op: ">"
    threshold: 85
    groupBy: [k8s.node.name]

  # PromQL
  - name: Cert Expiring
    type: promql
    query: "(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400"
    op: "<"
    threshold: 7
```

### Template Helpers (_helpers.tpl)
- `signoz-alerts.opCode` - Map `>`, `<`, `>=`, etc. to SigNoz op codes (1, 2, 3, etc.)
- `signoz-alerts.thresholdCondition` - Generate single-metric builder query
- `signoz-alerts.ratioCondition` - Generate A/B formula with two builder queries
- `signoz-alerts.promqlCondition` - Generate PromQL query

### Files to Modify

**`kubernetes/infra/signoz/templates/dashboard-sync-job.yaml`**
- Add kubectl to container (for ConfigMap discovery)
- Add section to discover ConfigMaps with label `signoz.homelab.io/alert=true`
- Keep existing dashboard loading from git (unchanged)
- Keep existing alerts/ directory loading as fallback during migration

**`kubernetes/infra/signoz/templates/rbac.yaml`** (new file)
- ClusterRole to list ConfigMaps across namespaces
- ClusterRoleBinding for the sync job's ServiceAccount

**`kubernetes/infra/signoz/templates/serviceaccount.yaml`** (new file)
- ServiceAccount for the sync job

### Migration Path
1. Create signoz-alerts chart
2. Update signoz PostSync job to also read from ConfigMaps
3. Optionally migrate existing alerts/ JSON files to signoz-alerts format
4. Existing JSON files continue to work (no breaking change)

---

## Implementation Order

### Phase 1: node-health (standalone, no dependencies)
1. Create `kubernetes/infra/node-health/Chart.yaml`
2. Create `kubernetes/infra/node-health/values.yaml`
3. Create `kubernetes/infra/node-health/templates/namespace.yaml`
4. Create `kubernetes/infra/node-health/templates/daemonset.yaml`
5. User: Set up healthchecks.io and Bitwarden secret
6. Deploy and verify pings appear in healthchecks.io

### Phase 2: signoz-alerts chart
1. Create `charts/signoz-alerts/Chart.yaml`
2. Create `charts/signoz-alerts/values.yaml`
3. Create `charts/signoz-alerts/templates/_helpers.tpl`
4. Create `charts/signoz-alerts/templates/configmap.yaml`
5. Create `charts/signoz-alerts/README.md`

### Phase 3: SigNoz integration
1. Create `kubernetes/infra/signoz/templates/serviceaccount.yaml`
2. Create `kubernetes/infra/signoz/templates/rbac.yaml`
3. Update `kubernetes/infra/signoz/templates/dashboard-sync-job.yaml`
4. Test with a sample app using signoz-alerts

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `kubernetes/infra/signoz/templates/dashboard-sync-job.yaml` | Modify for ConfigMap discovery |
| `kubernetes/infra/signoz/alerts/high-cpu.json` | Reference for ratio alert JSON structure |
| `charts/mdns-config/templates/configmap.yaml` | Pattern for labeled ConfigMap generation |
| `kubernetes/infra/tailscale-operator/values.yaml` | Pattern for bitwarden-secret integration |
