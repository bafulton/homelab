# Garage

S3-compatible object storage. The backup target for Longhorn volume backups and
for VolSync's restic repositories, replacing MinIO.

## Architecture

- **Deployment**: single-node StatefulSet on rpi5, `replicationFactor: 1`
- **Storage**: static hostPath PVs on the rpi5 USB disk (2 TB SanDisk Extreme SSD)
  - `/var/mnt/usb/garage/meta` — LMDB metadata
  - `/var/mnt/usb/garage/data` — object blocks
- **Buckets**: `longhorn-backups`, `volsync-backups` (created by the bootstrap job)
- **Credentials**: Bitwarden Secrets Manager via the `bitwarden-secret` chart
- **Ports**: 3900 S3 API, 3901 RPC, 3902 S3 web, 3903 admin API, 3909 web console

### Consumers

| Consumer | Configuration | Points at |
|---|---|---|
| Longhorn | `defaultBackupStore.backupTarget` in `infra/longhorn/values.yaml` | `s3://longhorn-backups@us-east-1/` |
| VolSync (restic) | `RESTIC_REPOSITORY` in `apps/jellyfin/values.yaml` | `volsync-backups/jellyfin-media` |

Garage is configured with `s3_region = "us-east-1"` so Longhorn's existing
`backupTarget` string needs no change — only the endpoint in
`longhorn-backup-credentials` differs from the MinIO era.

## Why hostPath Instead of a Longhorn PVC

Garage is the backup target for Longhorn, so a Longhorn PVC would be a circular
dependency: a Longhorn failure would take out the backups meant to recover from
it. hostPath on a separate physical disk on a separate node keeps the two
independent.

## Why This Upstream Chart

The dependency is `datahub-local/garage-helm`, a fork of the Deuxfleurs in-repo
chart. The official chart is not published to any Helm repository or OCI
registry, so it cannot be a chart-of-charts dependency. The fork adds the
declarative `clusterConfig` bootstrap (layout, buckets, key import) that keeps
cluster setup in Git rather than in one-off CLI commands.

The container image is upstream's `dxflrs/garage` in both cases — the fork ships
templates only, no binaries. Pin the chart version in `Chart.yaml` and upgrades
are a YAML review.

## Configuration

### Single-node constraints

Three values move together and must stay consistent:

- `deployment.kind: StatefulSet` — the bootstrap job resolves nodes by
  StatefulSet ordinal DNS (`garage-0.garage-headless.garage.svc.cluster.local`)
- `deployment.replicaCount: 1` — the job walks one host per replica
- `garage.replicationFactor: "1"` — one node holds one copy

### Storage

`persistence.*.storageClass` is `""`, which makes the StatefulSet's
`volumeClaimTemplates` emit no `storageClassName`. The generated PVCs
(`meta-garage-0`, `data-garage-0`) bind to the static PVs in
`templates/storage.yaml`, which pre-bind by `claimRef` so meta and data can
never swap paths.

`volumeClaimTemplates` are immutable, so the PV and PVC sizes are set generously
(10Gi meta, 1700Gi data) and left alone. Grow Garage's *usable* capacity instead
by adjusting the layout, which is a runtime operation:

```bash
kubectl exec -n garage garage-0 -- /garage layout assign -z rpi5 -c 1700G <node-id>
kubectl exec -n garage garage-0 -- /garage layout apply --version <next>
```

The PVs use `hostPath.type: Directory` so that a missing `/var/mnt/usb` mount
fails the pod outright. The `garage-permissions-fix` pre-install hook creates
and chowns the directories to `1000:1000` beforehand.

### Credentials

Three secret values live in Bitwarden Secrets Manager, surfaced as two
Kubernetes Secrets:

| Secret | Key | Contents |
|---|---|---|
| `garage-secret` | `rpcSecret` | 32-byte hex, node-to-node RPC auth |
| `garage-secret` | `adminToken` | 32-byte hex, admin API bearer token |
| `garage-s3-credentials` | `AWS_SECRET_ACCESS_KEY` | 32-byte hex, S3 secret key |

`AWS_ACCESS_KEY_ID` is a literal in `values.yaml`. Garage key IDs are public
identifiers like a username, and must match the format `GK` + 24 hex characters.

`garage.secret.create: false` is deliberate: left to generate its own, the chart
emits a fresh random `rpcSecret`/`adminToken` on every render, which ArgoCD would
re-apply and churn the pod on each sync.

Rotating `rpcSecret` or `adminToken` does not restart the pods on its own. The
pod-template `checksum/secret` annotation that would normally detect that is
suppressed via `ignoreDifferences` (see `values.yaml`), because the upstream
chart re-randomizes it on every render. Restart `garage-0` by hand after
rotating either value.

To rotate the S3 key:

1. Generate a new 32-byte hex value: `openssl rand -hex 32`
2. Update the secret in Bitwarden; External Secrets syncs within 1 minute
3. Re-run the bootstrap job so Garage imports the new secret for the same key ID
4. Update the consumers that hold a copy (`longhorn-backup-credentials`, the
   Jellyfin restic secret)

## Usage

The `garage` CLI ships inside the container and talks to the local node:

```bash
# Cluster state
kubectl exec -n garage garage-0 -- /garage status
kubectl exec -n garage garage-0 -- /garage layout show

# Buckets and usage
kubectl exec -n garage garage-0 -- /garage bucket list
kubectl exec -n garage garage-0 -- /garage bucket info longhorn-backups

# Keys and their grants
kubectl exec -n garage garage-0 -- /garage key list
kubectl exec -n garage garage-0 -- /garage key info longhorn-backup
```

The web console (`garage-webui`) is served at
**https://garage.catfish-mountain.com** for browsing buckets, keys and usage -
the replacement for the old MinIO console. catfish-mountain.com is
`wildcard_public = false`, so it resolves only through Tailscale Split DNS, the
same trust boundary as the Longhorn dashboard. Chart-level basic auth
(`webui.auth`) is therefore left off; enabling it requires an
`existingSecret` holding a `webuiAuthUserPass` bcrypt hash, because this chart
sets `garage.secret.create: false`.

## Monitoring

```bash
# Pod and bootstrap health
kubectl get pods -n garage
kubectl logs -n garage job/garage-configure

# Disk usage on the USB disk
talosctl -n 192.168.1.84 ls -lr /var/mnt/usb/garage | tail -1

# Backups that actually landed
kubectl get backups.longhorn.io -n longhorn
kubectl get replicationsources.volsync.backube -A
```

## Troubleshooting

### Bootstrap job never completes

`garage-configure` polls the admin API until every expected node answers. If it
logs `Waiting for garage-1 to be ready...`, `deployment.replicaCount` is greater
than 1 — set it back to 1.

### PVCs stay Pending

The PVs bind by `claimRef`, so confirm the PVC names match what the StatefulSet
generated:

```bash
kubectl get pvc -n garage          # expect meta-garage-0, data-garage-0
kubectl get pv garage-meta-rpi5-usb garage-data-rpi5-usb
```

A rename of the release or a change in `replicaCount` changes the PVC names; the
`claimRef` entries in `templates/storage.yaml` must follow.

### Pod cannot mount its volumes

`hostPath.type: Directory` means the USB disk must be mounted on rpi5:

```bash
talosctl -n 192.168.1.84 get mountstatus | grep /var/mnt/usb
```

If that is empty, the USB disk is not attached. Reattach it, then re-run the
`garage-permissions-fix` Job to recreate the directories.

### Longhorn cannot reach the backup target

```bash
kubectl exec -n longhorn $(kubectl get pods -n longhorn -l app=longhorn-manager -o name | head -1) -- \
  curl -sv http://garage.garage.svc.cluster.local:3900 2>&1 | head
```

Longhorn signs requests with the region in `backupTarget`; it must match
`s3_region` in the generated `garage.toml` (`us-east-1`).

## MinIO Migration

MinIO was archived upstream in April 2026 and its images were removed from every
public registry, so it could not be restarted after the rpi5 was re-flashed onto
official Talos. Garage replaces it.

The old MinIO tree is left in place at `/var/mnt/usb/minio-data` (~601 GiB: 4.6
GiB of Longhorn backups, 596 GiB of the Jellyfin restic repo). Backups were
re-baselined onto Garage rather than migrated — the retained history was four
restic snapshots and five Longhorn backups per volume, all months stale. Remove
`minio-data` once the new backups verify, which also reclaims the disk.
