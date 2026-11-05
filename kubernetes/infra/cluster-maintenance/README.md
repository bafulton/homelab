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

## ReplicaSet Cleanup CronJob

Cleans up old ReplicaSets to reduce clutter in the ArgoCD UI.

When Deployments are updated, Kubernetes keeps old ReplicaSets for rollback (default: 10 per Deployment). This CronJob removes excess old ReplicaSets.

### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `replicasetCleanup.enabled` | `true` | Enable/disable the cleanup CronJob |
| `replicasetCleanup.schedule` | `0 */6 * * *` | Cron schedule (every 6 hours) |
| `replicasetCleanup.keepPerDeployment` | `3` | Number of old ReplicaSets to keep per Deployment |

### Behavior

- Only deletes ReplicaSets with 0 replicas (inactive/old)
- Groups by owner Deployment and keeps the newest N
- Does not affect the current active ReplicaSet

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

## kubectl Image Version

The CronJobs use `bitnami/kubectl:latest` with `imagePullPolicy: IfNotPresent`. Pinning to a specific version was considered but rejected for this reason: Bitnami doesn't publish semantic version tags that map reliably to k8s versions, making Renovate automation require complex custom logic to track the cluster's k8s version. The operations performed (`kubectl delete pods`, `kubectl delete replicasets`) have been API-stable across all k8s versions, and the k8s skew policy allows kubectl to be ±1 minor version from the server, so `latest` with `IfNotPresent` is safe in practice.

## Logs

View cleanup logs:

```bash
# Pod cleanup
kubectl logs -n kube-system -l job-name=cleanup-succeeded-pods --tail=20
kubectl logs -n kube-system -l job-name=cleanup-failed-pods --tail=20

# ReplicaSet cleanup
kubectl logs -n kube-system -l job-name=cleanup-old-replicasets --tail=50

# fstrim (one job per node)
kubectl logs -n kube-system -l job-name --tail=20 | grep -A2 fstrim
```
