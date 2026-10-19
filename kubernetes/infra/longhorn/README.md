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

Naming by drive couples a PVC to a hardware detail. Because `storageClassName`
is immutable, such a name becomes a lie the moment the data moves, and cannot
be corrected without recreating the PVC. A purpose name stays true no matter
which drive the replica lands on.

All three classes are `reclaimPolicy: Retain`, so a deleted PVC leaves its PV
and Longhorn volume behind instead of destroying the data. That is what makes a
class migration a relabel rather than a copy (below), and it means a mistaken
PVC deletion is recoverable. The cost is orphaned PVs to clean up by hand.
`reclaimPolicy` is immutable on a StorageClass, so changing it means deleting
and recreating the class.

### Classes Longhorn creates for itself

Two classes are created by longhorn-manager rather than by this chart, so
neither carries an ArgoCD tracking-id and neither can be removed with
`kubectl delete` - the manager puts them straight back.

`longhorn` is gated by `persistence.createStorageClass: false`, which is what
actually removes it. Setting `defaultClass: false` alone is not enough: that
only un-defaults it, leaving behind a class that requests 3 replicas, which can
never schedule here (one node has Longhorn disks and
`replica-soft-anti-affinity` is false), so any PVC naming it would sit Pending
forever. The flag gates a ConfigMap the manager reads, so deleting the
StorageClass object by hand does nothing on its own.

`longhorn-static` cannot be removed at all. longhorn-manager recreates it from
the `default-longhorn-static-storage-class` setting, which Longhorn uses
internally for statically provisioned volumes - it reappeared within minutes of
being deleted. Nothing in this repo references it; leave it alone.

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

Moving a PVC between classes is a **relabel, not a copy**: `storageClassName`
is immutable on a PVC, but both `PV.spec.storageClassName` and
`PV.spec.claimRef` are mutable. With the PV on `reclaimPolicy: Retain`:

1. Quiesce the app and withdraw the PVC declaration so ArgoCD prunes the claim;
   the PV survives as `Released`, still holding the Longhorn volume
2. Patch the PV: `storageClassName` to the new class, and `claimRef` to the same
   namespace/name with `uid` and `resourceVersion` cleared - that returns it to
   `Available`, pre-bound by name
3. Restore the app with the new class; the recreated PVC binds back to the same
   volume

No data is read or written, so volume size is irrelevant - `time-machine-data`
moved 1.1TB this way in seconds. Verify afterwards that the PVC's `VOLUME`
column still shows the original `pvc-...` name.

A StatefulSet needs one more step, because `volumeClaimTemplates` is immutable
as well: delete the StatefulSet (at zero replicas there is nothing to orphan)
so it is recreated from the new template, then relabel the PVs as above. Where
an operator owns the StatefulSet - ClickHouse's belongs to
`ClickHouseInstallation/signoz-clickhouse`, not ArgoCD - quiesce through the
operator's own switch instead: the CHI honours `spec.stop: "yes"`, which
ArgoCD leaves alone because the chart renders no `stop` field.

### Verifying a recurring-job group actually applies

RecurringJobs match on **Volume** labels, and Longhorn copies
`recurring-job-group.longhorn.io/*` from the PVC to the Volume at provision
time - but not reliably. `mosquitto-data` was created with the label on its PVC
and the Volume came up with only `default`, so the backup schedule looked
correct in git and would have backed up nothing.

After adding a volume to a group, check the Volume, not the PVC:

```bash
kubectl get volumes.longhorn.io -n longhorn <pvc-...> -o jsonpath='{.metadata.labels}'
```

If the group label is missing, set it directly:

```bash
kubectl label volumes.longhorn.io -n longhorn <pvc-...> \
  recurring-job-group.longhorn.io/<group>=enabled --overwrite
```

A relabelled volume keeps its group labels, because the Volume object is never
recreated.

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

