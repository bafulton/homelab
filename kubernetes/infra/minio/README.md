# MinIO

S3-compatible object storage for Longhorn volume backups. Provides external backup target to protect against cluster-wide failures.

## Architecture

- **Deployment**: Single-node standalone mode on rpi5
- **Storage**: hostPath to `/var/mnt/usb/minio-data` (1.5TB capacity)
- **Credentials**: Managed via Bitwarden Secrets Manager
- **Bucket**: `longhorn-backups` (created automatically)

## Why hostPath Instead of Longhorn PVC?

MinIO serves as the backup target for Longhorn itself, so using a Longhorn PVC would create a circular dependency. The hostPath storage ensures backups remain accessible even if Longhorn has issues.

## Configuration

### Credentials

The MinIO root password is stored in Bitwarden Secrets Manager and synced via the `bitwarden-secret` chart. The root username (`longhorn-backup`) is hardcoded in `values.yaml`.

To update the password:
1. Update the secret in Bitwarden Secrets Manager
2. External Secrets Operator automatically syncs the new value within 1 minute

### Bucket Policy

The `longhorn-backups` bucket is created automatically with:
- **Policy**: `none` (private, no public access)
- **Purge**: `false` (never auto-delete)

## Usage

MinIO is accessed by Longhorn for automated backups. Manual access for troubleshooting:

### Via kubectl port-forward
```bash
kubectl port-forward -n minio svc/minio 9000:9000 9001:9001

# Console UI: http://localhost:9001
# Username: longhorn-backup
# Password: (from Bitwarden)
```

### Via MinIO Client (mc)
```bash
# Get password from secret
MINIO_PASSWORD=$(kubectl get secret -n minio minio-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)

# Configure alias
mc alias set homelab-minio http://minio.minio.svc.cluster.local:9000 longhorn-backup $MINIO_PASSWORD

# List buckets
mc ls homelab-minio

# List backups
mc ls homelab-minio/longhorn-backups
```

## Monitoring

### Disk Usage
```bash
# Check rpi5 USB free space
kubectl get nodes.longhorn.io rpi5 -n longhorn -o json | \
  jq '.status.diskStatus["usb-disk"].storageAvailable / 1024 / 1024 / 1024'

# Check MinIO data size
kubectl exec -n minio deploy/minio -- du -sh /data
```

### Pod Health
```bash
kubectl get pods -n minio
kubectl logs -n minio -l app=minio
```

## Backup Retention

Longhorn is configured for:
- **Daily snapshots**: 7 retained (local, fast recovery)
- **Weekly backups**: 4 retained (external, ~1 month of history)

With 4 weekly backups of a 1TB volume, expect:
- **Theoretical max**: 4TB
- **Actual usage**: ~500GB (due to compression and incremental backups)

## Troubleshooting

### Pod won't start
Check logs:
```bash
kubectl logs -n minio -l app=minio
kubectl describe pod -n minio -l app=minio
```

Common issues:
- **Credentials secret missing**: Check `kubectl get externalsecret -n minio`
- **hostPath doesn't exist**: Verify `/var/mnt/usb` is mounted on rpi5
- **Resource limits**: Check if rpi5 has sufficient CPU/memory

### Longhorn can't connect
```bash
# Test S3 connectivity from longhorn-manager
kubectl exec -n longhorn $(kubectl get pods -n longhorn -l app=longhorn-manager -o name | head -1) -- \
  curl -v http://minio.minio.svc.cluster.local:9000
```

### Check backup status
```bash
# Via Longhorn UI
open https://longhorn.catfish-mountain.com

# Or via CLI
kubectl get backups.longhorn.io -n longhorn
```
