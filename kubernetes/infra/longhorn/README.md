# Longhorn

Distributed block storage for Kubernetes. Provides persistent volumes with replication across nodes.

## Talos Requirements

Longhorn requires specific Talos configuration:

1. **System extensions** in Talos image:
   - `siderolabs/iscsi-tools` - iSCSI daemon for volume operations
   - `siderolabs/util-linux-tools` - Provides `nsenter` for volume trimming

2. **Kubelet mount** in `talconfig.yaml`:
   ```yaml
   machine:
     kubelet:
       extraMounts:
         - destination: /var/lib/longhorn
           type: bind
           source: /var/lib/longhorn
           options: [bind, rshared, rw]
   ```

3. **Kernel module** `iscsi_tcp` loaded

## ArgoCD Compatibility

The `preUpgradeChecker.jobEnabled` is disabled because ArgoCD runs Helm pre-upgrade hooks even on first install, which fails when the ServiceAccount doesn't exist yet.

## Storage Classes

Multiple storage classes target different disks:

| StorageClass | Disk | Use Case |
|--------------|------|----------|
| `longhorn-nvme` | NVMe SSD (2TB) | **Everything** - the default |
| `longhorn-emmc` | Internal eMMC (56GB) | Being retired, see below |

### Retiring `longhorn-emmc`

Put new volumes on `longhorn-nvme`. The eMMC tier is being removed: it is
beelink's boot device, and Talos EPHEMERAL (container images, logs, containerd
state) occupies most of it, leaving almost nothing safely schedulable.

| | |
|---|---|
| Disk total | 56.0 Gi |
| Talos EPHEMERAL | ~35.9 Gi |
| Longhorn 25% minimal-available floor | 14.0 Gi |
| **Safely usable by Longhorn** | **~6.1 Gi** |

`jellyfin-config` alone is 5.8 Gi actual, so the tier is structurally
over-committed rather than transiently full. When it crosses the floor the disk
reports `Schedulable=False` with `DiskPressure`, and Longhorn then refuses to
place *any* new replica there - which blocks replica rebuilds for the volumes
already on it. That is the deadlock behind the beelink power-loss incident, and
it blocked the VolSync restic cache from attaching until the cache moved to
`longhorn-nvme`.

Moving application writes off the boot device also protects the chip holding
the OS from wear.

Remaining volumes to migrate: `jellyfin-config`, `home-assistant-config`,
`matter-server-data`, `mosquitto-data`. A PVC's `storageClassName` is
immutable, so each is restore-from-backup into a new PVC on `longhorn-nvme`
(or recreate-empty for `mosquitto-data`, which has no backup job yet). Once
they are off, set `emmc-disk` to `allowScheduling: false`, then drop the disk
and the storage class.

TB-scale volumes on slow USB drives are not managed by Longhorn — Longhorn's V1 engine timeout (hard-capped at 30s) causes rebuild failures on large slow drives. Use the `local-storage` chart with VolSync for those instead.

Specify the storage class in your PVC:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  storageClassName: longhorn-nvme
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```
