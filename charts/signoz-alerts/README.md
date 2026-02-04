# signoz-alerts

Shared Helm chart for declarative SigNoz alert configuration.

## Overview

This chart generates labeled ConfigMaps containing SigNoz alert definitions. The SigNoz PostSync job automatically discovers these ConfigMaps and syncs them to SigNoz via the Management API.

## Usage

### Add as Dependency

```yaml
# Chart.yaml
dependencies:
  - name: signoz-alerts
    version: 1.0.0
    repository: file://../../../charts/signoz-alerts
    condition: signoz-alerts.enabled
```

### Define Alerts

```yaml
# values.yaml
signoz-alerts:
  enabled: true
  alerts:
    - name: High CPU
      description: Node CPU usage is above 90%
      severity: critical
      type: ratio
      metrics:
        numerator: k8s.node.cpu.usage
        denominator: k8s.node.allocatable_cpu
      multiply: 100
      op: ">"
      threshold: 90
      groupBy:
        - k8s.node.name
```

## Alert Types

### Threshold

Simple single-metric alert:

```yaml
- name: High Temperature
  description: Node temperature is above 85C
  type: threshold
  metric: node_hwmon_temp_celsius
  timeAggregation: max    # avg, min, max, sum, latest
  spaceAggregation: max   # avg, min, max, sum
  op: ">"                 # > or < (for other operators, use type: promql)
  threshold: 85
  groupBy:
    - instance
```

### Ratio

Percentage calculation (A/B):

```yaml
- name: High Memory
  description: Memory usage above 85%
  type: ratio
  metrics:
    numerator: k8s.node.memory.working_set
    denominator: k8s.node.allocatable_memory
  multiply: 100  # Optional multiplier
  op: ">"
  threshold: 85
  groupBy:
    - k8s.node.name
```

### PromQL

Complex queries:

```yaml
- name: Certificate Expiring
  description: Cert expires within 7 days
  type: promql
  query: "(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400"
  op: "<"
  threshold: 7
  legend: "{{namespace}}/{{name}}"
```

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `enabled` | Enable/disable alert generation | `true` |
| `defaults.severity` | Default severity level | `warning` |
| `defaults.evalWindow` | Evaluation window | `5m0s` |
| `defaults.frequency` | Check frequency | `1m0s` |
| `defaults.notificationChannel` | SigNoz channel UUID | Gmail channel |
| `alerts[]` | Array of alert definitions | `[]` |

## Alert Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `name` | Yes | Alert name (must be unique) |
| `description` | Yes | Alert description |
| `type` | Yes | `threshold`, `ratio`, or `promql` |
| `severity` | No | `warning` or `critical` |
| `op` | Yes | `>` or `<` (for other operators, use `type: promql`) |
| `threshold` | Yes | Numeric threshold value |
| `groupBy` | No | Array of grouping attributes |
| `filter` | No | Filter expression |
| `evalWindow` | No | Override eval window |
| `frequency` | No | Override check frequency |
| `stepInterval` | No | Aggregation interval in seconds (default: 60) |
| `legend` | No | Legend template |

## How It Works

1. App includes `signoz-alerts` chart dependency
2. Chart generates ConfigMaps labeled `signoz.homelab.io/alert: "true"`
3. SigNoz PostSync job discovers ConfigMaps across all namespaces
4. Job syncs alert JSON to SigNoz via Management API
5. Alerts appear in SigNoz UI, updates preserved

## Examples

See `values.yaml` for complete examples of all alert types.
