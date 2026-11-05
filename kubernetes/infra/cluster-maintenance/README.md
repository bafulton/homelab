# Cluster Maintenance

Cluster-level maintenance utilities deployed to `kube-system` namespace.

## Pod Cleanup CronJob

Automatically cleans up terminated pods to prevent accumulation.

Kubernetes' default garbage collection threshold (12500 pods) is too high for small clusters, so this CronJob provides more aggressive cleanup.

### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `podCleanup.enabled` | `true` | Enable/disable the cleanup CronJob |
| `podCleanup.succeededSchedule` | `* * * * *` | Cron schedule for Succeeded pods (every minute) |
| `podCleanup.failedSchedule` | `0 * * * *` | Cron schedule for Failed pods (every hour) |

### Behavior

- **Succeeded (Completed) pods**: Deleted every minute. These are typically finished Jobs with no debugging value.
- **Failed pods**: Deleted every hour, giving time for debugging.

## Deployment rollback history

The Deployment controller owns ReplicaSet retention. Repo-owned Deployment
manifests set `spec.revisionHistoryLimit: 3`; upstream charts that expose this
setting (Home Assistant, Jellyfin, Argo CD, Traefik, and Node Feature Discovery)
also use three old revisions. Other upstream charts retain the Kubernetes
default of ten old revisions when they do not expose a chart value. Talos owns
CoreDNS, so its Deployment also keeps the Kubernetes default.

These are counts of **old** ReplicaSets, in addition to the current revision.
The Deployment controller handles each Deployment by namespace and UID and
preserves its current revision even when scaled to zero. It prunes history
only after a rollout is complete; a paused or failed rollout may temporarily
exceed the limit. `kubectl rollout undo` can reach only retained revisions.
For older versions, revert the Git change (or use the image version from Git)
and let Argo CD reconcile a new revision.

## CoreDNS Spread CronJob

Keeps the two cluster CoreDNS replicas on different nodes, so one node failing
or the Tailscale link dropping can't take out cluster DNS.

Talos owns the `coredns` Deployment and its anti-affinity is only a preference,
so both replicas stayed on `ocifree` after the 2026-10-26 outage. The
`coredns-spread` CronJob adds a required anti-affinity with `kubectl apply
--server-side` under its own field manager. `talosctl upgrade-k8s` leaves that
field alone because Talos doesn't own it; the daily run re-applies it after
anything else that resets the Deployment, and is a no-op otherwise.

The first apply changes the pod template, so CoreDNS does a rolling restart.

Run it by hand:

```bash
kubectl -n kube-system create job --from=cronjob/coredns-spread coredns-spread-manual
```

## fstrim CronJobs

One CronJob per node (`fstrim-<node>`), Sundays 06:30 UTC, trims the SSD-backed
data filesystems listed under `fstrim.nodes` in `values.yaml`:

| Node | Paths |
|------|-------|
| beelink | `/var/mnt/nvme` (Longhorn), `/var/mnt/usb` (Jellyfin media), `/var/mnt/tm` (Time Machine) |
| rpi5 | `/var/mnt/usb` (Garage + Longhorn) |

Talos runs no periodic trim and these xfs mounts have no `discard` option, so
without this the drives never learn which blocks are free. The pods are
privileged (FITRIM needs `CAP_SYS_ADMIN`) and use the toolbox image's BusyBox
`fstrim`. Add a node or drive by extending the list.

Run one by hand:

```bash
kubectl create job -n kube-system --from=cronjob/fstrim-beelink fstrim-beelink-manual
```

## kubectl image version

The pod cleanup and CoreDNS spread CronJobs use the versioned homelab toolbox
image set in `values.yaml`. Keep its kubectl minor version aligned with the
API server when updating the image.

## Logs

View maintenance logs:

```bash
# Pod cleanup
kubectl logs -n kube-system -l job-name=cleanup-succeeded-pods --tail=20
kubectl logs -n kube-system -l job-name=cleanup-failed-pods --tail=20

# fstrim (one job per node)
kubectl logs -n kube-system -l job-name --tail=20 | grep -A2 fstrim
```
