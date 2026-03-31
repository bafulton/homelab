# local-storage

A reusable Helm chart for creating static hostPath PVs/PVCs with optional VolSync backups. Parallel to `longhorn-storage` — use this for large or performance-sensitive volumes that don't benefit from Longhorn replication (e.g., TB-scale media libraries pinned to a single node).

## When to Use This vs. longhorn-storage

| | `longhorn-storage` | `local-storage` |
|--|---|---|
| **Replication** | Yes (across nodes) | No (single node) |
| **Volume mobility** | Yes | No (pinned to node) |
| **Best for** | Config volumes, small data | TB+ media, node-pinned drives |
| **Backups** | Longhorn RecurringJobs → MinIO | VolSync restic → MinIO |

If your volume is already pinned to a node via `nodeSelector` and is too large for Longhorn to rebuild (>~100GB on slow drives), use `local-storage`.

## Usage

Add as a dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: local-storage
    version: 1.0.0
    repository: file://../../../charts/local-storage
```

Configure in your `values.yaml`:

```yaml
local-storage:
  pvcs:
    - name: my-app-media
      path: /var/mnt/usb/my-app     # hostPath on the node
      size: 2Ti
      node: beelink                  # Node with the disk
      backup:                        # Optional VolSync backup
        schedule: "0 8 * * 0"        # Weekly on Sundays at 8am UTC
        repository: my-restic-secret # Kubernetes secret name
        retain:
          weekly: 3
          monthly: 1
```

Then reference the PVC in your app:

```yaml
my-app:
  persistence:
    existingClaim: my-app-media
```

## Backup Prerequisites

To use the `backup` field, you need:

1. **VolSync operator** deployed (`kubernetes/infra/volsync`)
2. **A Kubernetes secret** with restic credentials (use `bitwarden-secret` chart):

```yaml
bitwarden-secret:
  secrets:
    - name: my-restic-secret
      data:
        RESTIC_REPOSITORY: "s3:http://minio.minio.svc.cluster.local:9000/volsync-backups/my-app"
        AWS_ACCESS_KEY_ID: "longhorn-backup"
        AWS_SECRET_ACCESS_KEY: "<bitwarden-uuid>"
        RESTIC_PASSWORD: "<bitwarden-uuid>"
```

## Values

### PVCs

| Key | Description | Default |
|-----|-------------|---------|
| `pvcs` | List of PVC configurations | `[]` |
| `pvcs[].name` | PV and PVC name | Required |
| `pvcs[].path` | hostPath directory on the node | Required |
| `pvcs[].size` | Storage size (informational for hostPath) | Required |
| `pvcs[].node` | Node name for PV nodeAffinity | Required |
| `pvcs[].accessMode` | Access mode | `ReadWriteOnce` |

### Backups (optional)

| Key | Description | Default |
|-----|-------------|---------|
| `pvcs[].backup` | VolSync ReplicationSource config | - |
| `pvcs[].backup.schedule` | Cron schedule for backups | Required |
| `pvcs[].backup.repository` | Name of the restic credentials Secret | Required |
| `pvcs[].backup.retain.weekly` | Weekly backups to keep | - |
| `pvcs[].backup.retain.monthly` | Monthly backups to keep | - |

## How It Works

1. A **PersistentVolume** is created pointing to the hostPath with nodeAffinity locking it to the specified node
2. A **PersistentVolumeClaim** binds to it by name (`storageClassName: ""`)
3. If `backup` is configured, a **VolSync ReplicationSource** is created that reads the live PVC directly (`copyMethod: Direct`) and backs it up via restic on schedule

`copyMethod: Direct` reads the live PVC without needing a CSI snapshot — safe for read-mostly volumes like media libraries.

## Resources Created

For each entry in `pvcs`:
- **PersistentVolume**: `<name>` (cluster-scoped, hostPath, Retain policy)
- **PersistentVolumeClaim**: `<name>` bound to the PV

For each entry with `backup`:
- **ReplicationSource**: `<name>` (VolSync, restic, Direct copy method)
