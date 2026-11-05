# Longhorn

Distributed block storage for Kubernetes. Provides persistent volumes with replication across nodes.

## Talos Requirements

Longhorn requires specific Talos configuration:

1. **System extensions** in Talos image:
   - `siderolabs/iscsi-tools` - iSCSI daemon for volume operations
   - `siderolabs/util-linux-tools` - Provides `nsenter` for volume trimming

2. **Kubelet mount** in `talos/patches/all.yaml`:
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

| StorageClass | Meaning | Replicas | Workload runs on | Backed up |
|--------------|---------|----------|------------------|-----------|
| `config` | Small, precious application config | 2 (beelink NVMe + rpi5 USB) | Any node | Yes, via per-app RecurringJobs |
| `state` | Operational state - rebuildable, or too large to back up | 1, `strict-local` | beelink only | No |
| `scratch` | Disposable; losing it costs a slower next run | 1, `strict-local` | beelink only | No |

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

### The rule: replicated, or pinned

> A volume with a second replica may run anywhere. A single-replica volume runs
> only on the node holding its replica.

Every class follows this, because of how a node drain works with Longhorn. A
drain must evict the node's `instance-manager` pod, and Longhorn holds a PDB on
it while any replica there is the last healthy copy of a volume that is in use.
If a single-replica volume's pod runs on *another* node, its replica on the
drained node is still live, the PDB never lifts, and the drain hangs - and with
it every tuppr Talos upgrade (`kubernetes/infra/tuppr`) and every
`safe-reboot-node.sh` run. (`nodeDrainPolicy: allow-if-replica-is-stopped`
releases the PDB once the node's replicas are *stopped*; it cannot help while
one is in use elsewhere.)

The rule is enforced three ways:

- **`config`** keeps two replicas on different nodes (`durable` disks, hard
  replica anti-affinity), so draining either node leaves a live copy and the
  app keeps running.
- **`state` and `scratch`** are `dataLocality: strict-local`, so Longhorn
  refuses to attach the volume on any node but its replica's. Workloads using
  them also carry `nodeSelector: kubernetes.io/hostname: beelink`, with a
  comment saying why (ClickHouse, ZooKeeper, the SigNoz app).
- **tuppr's health checks** refuse to start an upgrade while any Longhorn
  volume is neither replicated nor strict-local, so a violation shows up as a
  waiting upgrade with a `HealthChecksFailed` event rather than a hung drain.

Choosing a class for a new volume: `config` if the app must survive a beelink
reboot and its data is small and lightly written; `state` if it is large,
write-heavy or rebuildable - and then pin its workload to beelink.

### Classes Longhorn creates for itself

Two classes are created by longhorn-manager rather than by this chart, so
neither carries an ArgoCD tracking-id and neither can be removed with
`kubectl delete` - the manager puts them straight back.

`longhorn` is gated by `persistence.createStorageClass: false`, which is what
actually removes it. Setting `defaultClass: false` alone is not enough: that
only un-defaults it, leaving behind a class that requests 3 replicas, which can
never schedule across the two Longhorn storage nodes with
`replica-soft-anti-affinity` false, so any PVC naming it would sit Pending
forever. The flag gates a ConfigMap the manager reads, so deleting the
StorageClass object by hand does nothing on its own.

`longhorn-static` cannot be removed at all. longhorn-manager recreates it from
the `default-longhorn-static-storage-class` setting, which Longhorn uses
internally for statically provisioned volumes. In a previous cleanup attempt,
it reappeared within minutes of deletion. Nothing in this repo references it;
leave it alone.

### How a class maps to a drive

```
talos/patches/      device: /dev/disk/by-id/nvme-...  →  mountpoint: /var/mnt/nvme
       ↓
nodeConfig          nvme-disk: path=/var/mnt/nvme  tags=["durable","nvme"]   ← tags are born here
                    usb-disk (rpi5): path=/var/mnt/usb  tags=["durable"]
       ↓
StorageClass        parameters.diskSelector = "durable"                     ← the only join
       ↓
PVC                 storageClassName: config                                (immutable)
       ↓
Volume              spec.diskSelector: ["durable"]   ← copied at provision, then independent
```

`diskSelector` matches the `tags` on each disk in `nodeConfig`. That one line is
where intent meets hardware: moving a purpose to a different drive is an edit
here plus a replica migration, never PVC surgery. No class selects every disk:
an added disk collects volumes only once it carries a tag a class asks for.
`durable` is beelink's NVMe plus a 50 GiB share of rpi5's USB SSD, which it
shares with Garage (`storageReserved` sets the share - lower it to grow
Longhorn's).

Note the last step: a volume copies `diskSelector`, `numberOfReplicas` and
`dataLocality` once, at provision time, and ignores its class afterwards. That
is why the PVC's class name is only a provisioning-time label, and why changing
a class needs the existing volumes converted by hand:

- **To replicated:** patch the Volume's `spec.diskSelector` and
  `spec.numberOfReplicas` together. Longhorn builds the new replica while the
  volume stays attached.
- **To strict-local:** Longhorn only allows it on a **detached** single-replica
  volume. Quiesce the app (through Git, or the CHI's `spec.stop` for
  ClickHouse), patch `spec.dataLocality`, then bring the app back.

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

RecurringJobs match **Volume** labels. Longhorn only synchronizes a PVC's
recurring-job labels when it has `recurring-job.longhorn.io/source=enabled`.
Without it, a group on the PVC can leave the Volume in `default` only.
The shared `longhorn-storage` chart now sets the source label and both the app
and `default` groups. The latter retains `trim-daily`: once the PVC is the
source, its recurring-job labels replace the Volume's labels. Matter Server's
direct PVC template follows the same rule. See [Longhorn's recurring-job
documentation](https://longhorn.io/docs/1.13.0/snapshots-and-backups/scheduling-backups-and-snapshots/).

For an existing protected PVC, first inspect its Volume labels for any
manually assigned jobs or groups that must survive. Put those labels on its PVC
template before enabling the source label. After ArgoCD sync, compare both:

```bash
kubectl get pvc -n pocket-id pocket-id-data --show-labels
pv=$(kubectl get pvc -n pocket-id pocket-id-data -o jsonpath='{.spec.volumeName}')
volume=$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}')
kubectl get volumes.longhorn.io -n longhorn "$volume" --show-labels
kubectl get recurringjobs.longhorn.io -n longhorn pocket-id-daily pocket-id-backup trim-daily
```

The PVC and Volume should both have `recurring-job-group.longhorn.io/pocket-id`
and `recurring-job-group.longhorn.io/default`; the PVC also has the source
label. Repeat for `home-assistant-config`, `matter-server-data`,
`jellyfin-config`, and `mosquitto-data`. The app group supplies snapshot and
backup jobs, while `default` supplies trim. If labels differ, inspect the PVC,
Volume, and Longhorn manager logs before changing a Volume directly.

To test new provisioning, create a disposable `config` PVC with the source,
`default`, and a test group labels. The StorageClass binds immediately; check
that the bound Volume gets both groups
without a manual Volume label. Delete the pod and PVC afterward; the class has
`Retain`, so inspect and clean up the test PV/Volume explicitly.

After sync, run a Pocket ID backup from Longhorn's Volume UI and wait for it to
complete. Check the backup store entry and the Volume's timestamp:

```bash
kubectl get volumes.longhorn.io -n longhorn "$volume" -o jsonpath='{.status.lastBackupAt}{"\n"}'
kubectl get backups.longhorn.io -n longhorn -o wide
```

The timestamp must advance, and the corresponding backup must be `Completed`
in the configured Garage backup target. The five SigNoz Longhorn backup alerts
fire when a protected volume has no successful backup timestamp or its latest
backup is more than 36 hours old. Confirm the Pocket ID alert resolves after
the backup and that the other protected volumes retain their intended jobs.

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

