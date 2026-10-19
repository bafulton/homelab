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

Classes are named for what the data **is**, not which drive it sits on.

| StorageClass | Meaning | Backed up |
|--------------|---------|-----------|
| `config` | Small, precious application config | Yes, via per-app RecurringJobs |
| `state` | Operational state - rebuildable, or too large to back up | No |
| `scratch` | Disposable; losing it costs a slower next run | No |

Naming by drive (the previous `longhorn-emmc` / `longhorn-nvme` scheme) couples
a PVC to a hardware detail. Because `storageClassName` is immutable, the name
becomes a lie the moment data moves and cannot be corrected without recreating
the PVC - which is exactly what happened when the eMMC tier was vacated: four
PVCs still name `longhorn-emmc` while their data lives on nvme.

### How a class maps to a drive

```
talconfig.yaml      device: /dev/disk/by-id/nvme-...  →  mountpoint: /var/mnt/nvme
       ↓
nodeConfig          nvme-disk: path=/var/mnt/nvme  tags=["nvme"]     ← tags are born here
       ↓
StorageClass        parameters.diskSelector = "nvme"                 ← the only join
       ↓
PVC                 storageClassName: config                         (immutable)
       ↓
Volume              spec.diskSelector: ["nvme"]   ← copied at provision, then independent
```

`diskSelector` matches the `tags` on each disk in `nodeConfig`. That one line is
where intent meets hardware: moving a purpose to a different drive is an edit
here plus a replica migration, never PVC surgery. All three classes point at
`nvme` today, deliberately - an explicit selector keeps the divergence point
visible rather than letting an added disk silently collect volumes.

Note the last step: a volume copies `diskSelector` once, at provision time, and
ignores its class afterwards. That is why the PVC's class name is only a
provisioning-time label, and why stale ones are harmless.

### Migration state

`storageClassName` is immutable, so each app moves to a new class only when its
PVC is recreated. This is done opportunistically rather than as a big-bang.

| PVC | Current | Target |
|-----|---------|--------|
| `mosquitto/mosquitto-data` | `config` | done (pilot) |
| `home-assistant/home-assistant-config` | `longhorn-emmc` | `config` |
| `home-assistant/matter-server-data` | `longhorn-emmc` | `config` |
| `jellyfin/jellyfin-config` | `longhorn-emmc` | `config` |
| `signoz/*` (3 StatefulSet templates) | `longhorn-nvme` | `state` |
| `time-machine/time-machine-data` | `longhorn-nvme` | `state` |
| `jellyfin/volsync-src-...-cache` | `longhorn-nvme` | `scratch` |

`longhorn-emmc` and `longhorn-nvme` are retained until nothing names them, then
deleted. `longhorn-static` was removed already, having had no references.

The chart-provided `longhorn` class is removed via
`persistence.createStorageClass: false`. Setting `defaultClass: false` alone is
not enough - that only un-defaults it, leaving a class behind that requests 3
replicas, which can never schedule here.

TB-scale node-pinned volumes do not use Longhorn at all; see the
`local-storage` chart. Longhorn's V1 engine timeout (hard-capped at 30s) causes
rebuild failures on large slow drives.

### Migrating replicas between disks

Changing a class's `diskSelector` only affects where **new** replicas land.
Moving existing data takes three steps, because Longhorn will not evict the
last replica of an attached single-replica volume:

1. Repoint each volume's `spec.diskSelector` to the new tag
2. Temporarily set `replica-soft-anti-affinity: true` and the volume's
   `numberOfReplicas: 2`, so a second replica builds on the target disk - strict
   node anti-affinity otherwise blocks it when the target exists on one node only
3. Once healthy, drop back to `numberOfReplicas: 1` and set
   `spec.evictionRequested: true` on the **replica** objects

Set eviction on the replicas, not the disk: `templates/node-config.yaml` renders
`evictionRequested: false` for every disk, so ArgoCD reverts a disk-level
request within seconds. Revert `replica-soft-anti-affinity` afterwards.

