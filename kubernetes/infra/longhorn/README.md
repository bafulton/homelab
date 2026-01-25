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
| `longhorn-emmc` | Internal eMMC (56GB) | Small apps, configs |
| `longhorn-nvme` | NVMe SSD (2TB) | Large/write-heavy workloads |
| `longhorn-usb` | USB drives | Media libraries (replicated across nodes) |

Specify the storage class in your PVC:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  storageClassName: longhorn-emmc  # or longhorn-nvme
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```
