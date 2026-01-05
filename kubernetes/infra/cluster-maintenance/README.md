# Cluster Maintenance

Cluster-level maintenance utilities deployed to `kube-system`.

## Pod Cleanup CronJob

Automatically cleans up terminated pods to prevent accumulation.

Kubernetes' default garbage collection threshold (12500 pods) is too high for small clusters, so this CronJob provides more aggressive cleanup.

### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `podCleanup.enabled` | `true` | Enable/disable the cleanup CronJob |
| `podCleanup.schedule` | `* * * * *` | Cron schedule (default: every minute) |
| `podCleanup.succeededPodMaxAge` | `0` | Seconds before deleting Succeeded pods (0 = immediate) |
| `podCleanup.failedPodMaxAge` | `3600` | Seconds before deleting Failed pods (default: 1 hour) |

### Behavior

- **Succeeded (Completed) pods**: Deleted immediately by default. These are typically finished Jobs with no debugging value.
- **Failed pods**: Kept for 1 hour for debugging, then deleted.

### Logs

View cleanup logs:

```bash
kubectl logs -n kube-system -l job-name --tail=50
```

Or for a specific run:

```bash
kubectl logs -n kube-system job/pod-cleanup-<timestamp>
```
