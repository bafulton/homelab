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

## Logs

View cleanup logs:

```bash
# Pod cleanup
kubectl logs -n kube-system -l job-name=cleanup-succeeded-pods --tail=20
kubectl logs -n kube-system -l job-name=cleanup-failed-pods --tail=20

# ReplicaSet cleanup
kubectl logs -n kube-system -l job-name=cleanup-old-replicasets --tail=50
```
