# VolSync

Kubernetes operator for asynchronous volume replication. Used in this cluster to back up PVCs to MinIO via restic.

## Overview

VolSync runs as a controller that watches `ReplicationSource` resources and copies PVC data to an external destination on a schedule. This cluster uses it specifically for backing up volumes managed by the `local-storage` chart — hostPath PVCs that Longhorn can't snapshot (too large, slow drives).

## How It Works

```
ReplicationSource (jellyfin-media, weekly)
        │
        ▼
VolSync reads PVC directly (copyMethod: Direct)
        │
        ▼
restic backs up to MinIO (volsync-backups bucket)
        │
        ▼
Deduplicated, encrypted backup at rest
```

`copyMethod: Direct` reads the live PVC without snapshotting — safe for read-mostly volumes like media libraries where momentary inconsistency is acceptable.

## Usage

VolSync is consumed via the `local-storage` chart's `backup` field. You don't interact with VolSync directly — just configure backups in your app's `values.yaml`:

```yaml
local-storage:
  pvcs:
    - name: my-media
      path: /var/mnt/usb/my-media
      size: 2Ti
      node: beelink
      backup:
        schedule: "0 8 * * 0"
        repository: my-restic-secret  # Secret with RESTIC_* env vars
        retain:
          weekly: 3
          monthly: 1
```

See `charts/local-storage/README.md` for full configuration details.

## Monitoring

Check ReplicationSource status:

```bash
kubectl get replicationsource -A
kubectl describe replicationsource jellyfin-media -n jellyfin
```

A successful backup shows `.status.lastSyncTime` updated and `.status.conditions` with `Synchronizing: False`.

## Current Consumers

| App | Volume | Schedule | Retention |
|-----|--------|----------|-----------|
| jellyfin | `jellyfin-media` | Sundays 3am EST | 3 weekly, 1 monthly |
