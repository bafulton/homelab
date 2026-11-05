# longhorn-storage

A reusable Helm chart for creating Longhorn PVCs with optional recurring snapshot/backup jobs.

## Features

- Create PVCs with configurable size, storageClass, and accessMode
- Optional PVC-to-Volume synchronization of recurring-job groups
- RecurringJob creation targeting labeled volumes
- Pure IaC approach to Longhorn backups

## Usage

Add as a dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: longhorn-storage
    version: 1.0.0
    repository: file://../../../charts/longhorn-storage
    condition: longhorn-storage.enabled
```

Configure in your `values.yaml`:

```yaml
longhorn-storage:
  # Create a PVC with backup enabled
  pvcs:
    - name: my-app-data
      size: 10Gi
      backupGroup: my-app  # Enables recurring snapshots

  # Create a recurring job targeting the backup group
  jobs:
    - name: my-app-daily
      cron: "0 3 * * *"  # Daily at 3 AM
      groups:
        - my-app         # Matches PVCs with backupGroup: my-app
      retain: 7          # Keep 7 snapshots
```

Then reference the PVC in your app:

```yaml
my-app:
  persistence:
    existingClaim: my-app-data
```

## Values

### PVCs

| Key | Description | Default |
|-----|-------------|---------|
| `pvcs` | List of PVC configurations | `[]` |
| `pvcs[].name` | PVC name | Required |
| `pvcs[].size` | Storage size | `1Gi` |
| `pvcs[].storageClass` | Longhorn storage class (`config`, `state`, `scratch`) | `config` |
| `pvcs[].accessMode` | Access mode | `ReadWriteOnce` |
| `pvcs[].backupGroup` | Adds the source label plus `<group>` and `default` recurring-job groups to the PVC | - |

### RecurringJobs

| Key | Description | Default |
|-----|-------------|---------|
| `longhornNamespace` | Namespace for RecurringJob resources | `longhorn` |
| `jobs` | List of RecurringJob configurations | `[]` |
| `jobs[].name` | RecurringJob name | Required |
| `jobs[].cron` | Cron schedule | Required |
| `jobs[].groups` | Volume groups to target | Required |
| `jobs[].task` | `snapshot` or `backup` | `snapshot` |
| `jobs[].retain` | Number of snapshots/backups to keep | `5` |
| `jobs[].concurrency` | Max concurrent jobs | `1` |

## How It Works

1. PVCs with `backupGroup` get `recurring-job.longhorn.io/source: enabled`, their app group, and the `default` group.
2. Longhorn synchronizes those recurring-job labels to the Volume, including existing bound volumes. The PVC becomes authoritative for recurring-job labels on that Volume.
3. RecurringJobs target Volume groups; `default` retains the cluster-wide trim job.
4. Longhorn snapshots or backs up matching attached volumes on schedule.

Before enabling `backupGroup` on a PVC that already has Volume-level recurring-job labels, add every job/group that should survive synchronization to the PVC. See the [Longhorn runbook](../../kubernetes/infra/longhorn/README.md#verifying-a-recurring-job-group-actually-applies).

## Resources Created

For each entry in `pvcs`:
- **PersistentVolumeClaim**: `<name>` with optional backup group label

For each entry in `jobs`:
- **RecurringJob**: `<name>` in the Longhorn namespace
