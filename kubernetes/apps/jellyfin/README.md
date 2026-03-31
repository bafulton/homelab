# Jellyfin

Self-hosted media server with Intel QuickSync hardware transcoding. 100% free and open source.

## Access

| Method | URL | Use Case |
|--------|-----|----------|
| LAN | `http://media.local` | Local access on home network |
| Private (Tailscale) | `https://jellyfin.catfish-mountain.com` | Remote access via Tailscale |

**Clients:**
- **Web UI**: Built-in, works in any browser
- **Apple devices**: Infuse (paid, polished UI) or native Jellyfin apps (free)
- **Other platforms**: Native Jellyfin apps (Android, Roku, Fire TV, etc.)

## Storage

| PVC | Size | Backed by | Backup |
|-----|------|-----------|--------|
| `jellyfin-config` | 5Gi | Longhorn (longhorn-emmc) | Daily snapshots via Longhorn (5 retained) |
| `jellyfin-media` | 2Ti | Static hostPath on beelink (`/var/mnt/usb/jellyfin-media`) | Weekly restic backup to MinIO via VolSync (3 weekly, 1 monthly) |

`jellyfin-media` is managed by the `local-storage` chart rather than Longhorn — Longhorn's engine timeout is incompatible with TB-scale volumes on slow USB drives. VolSync reads the live PVC directly (no snapshot step) and backs up via restic deduplication.

## Hardware Transcoding

Uses Intel QuickSync via the iGPU on nodes with Intel GPUs. Requires:
- **Talos extension**: `siderolabs/i915` (GPU firmware)
- **Infrastructure**: `intel-device-plugins` deployed first

The pod requests `gpu.intel.com/i915: 1` to access the GPU.

### Enable in Jellyfin UI

1. Go to Dashboard > Playback > Transcoding
2. Set Hardware acceleration to **Intel QuickSync (QSV)**
3. Enable hardware decoding for: H264, HEVC, VP9, AV1
4. Enable "Allow encoding in HEVC format"

## Media Organization

Jellyfin expects specific folder structures:

### Movies
```
/media/Movies/
├── Inception (2010)/
│   └── Inception (2010).mkv
└── The Matrix (1999)/
    └── The Matrix (1999).mkv
```

### TV Shows
```
/media/TV Shows/
└── Breaking Bad (2008)/
    ├── Season 01/
    │   ├── Breaking Bad S01E01.mkv
    │   └── Breaking Bad S01E02.mkv
    └── Season 02/
        └── Breaking Bad S02E01.mkv
```

## Restoring Media from External USB Drive

The media library lives at `/var/mnt/usb/jellyfin-media` on `beelink`. To restore from an external drive (e.g. after a wipe), use a privileged pod. These steps assume the source drive is exFAT-formatted with media in `Ben's Data/Movies` and `Ben's Data/TV Shows`.

### 1. Identify the source device

Plug in the drive, then list disks on beelink:

```bash
talosctl get disks -n 192.168.1.86
```

Look for the newly appeared USB device (e.g. `sdj`). Confirm its partition:

```bash
talosctl read /proc/partitions -n 192.168.1.86 | grep sdj
# e.g. sdj1
```

Cross-check which device is already mounted (so you don't confuse source/dest):

```bash
talosctl read /proc/mounts -n 192.168.1.86 | grep '/dev/sd'
# /dev/sda1 /var/mnt/usb xfs ... ← that's the jellyfin-media drive; source is the other one
```

Confirm the filesystem type from inside a privileged pod (see step 2):

```bash
kubectl exec -n minio media-import -- blkid /dev/sdj1
# Should show TYPE="exfat"
```

### 2. Create the import pod

The pod runs in the `minio` namespace (already labeled `privileged`), pinned to beelink, with three hostPath volumes: the host `/dev` tree (for raw device access), the host kernel modules (for `modprobe`), and the destination directory.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: media-import
  namespace: minio
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: beelink
  containers:
    - name: import
      image: alpine:latest
      command: ["sh", "-c", "apk add --no-cache rsync && sleep infinity"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: host-dev
          mountPath: /dev
        - name: host-modules
          mountPath: /lib/modules
        - name: destination
          mountPath: /mnt/dst
  volumes:
    - name: host-dev
      hostPath:
        path: /dev
    - name: host-modules
      hostPath:
        path: /lib/modules
    - name: destination
      hostPath:
        path: /var/mnt/usb/jellyfin-media
EOF

kubectl wait --for=condition=Ready pod/media-import -n minio --timeout=120s
```

> **Why `minio` namespace?** The `jellyfin` namespace doesn't have the `privileged` pod-security label, so direct `hostPath` volumes in pod specs are blocked there. The `minio` namespace is already labeled privileged.

### 3. Mount the exFAT drive

The Talos kernel on beelink does **not** have the native exFAT module, but does have FUSE. Use `fuse-exfat`:

```bash
kubectl exec -n minio media-import -- sh -c "
  modprobe fuse
  apk add --no-cache fuse fuse-exfat
  mkdir -p /mnt/src
  mount.exfat-fuse /dev/sdj1 /mnt/src
  ls /mnt/src
"
```

### 4. Run rsync in the background

Both copy operations run sequentially, logged to `/tmp/rsync.log` inside the pod:

```bash
kubectl exec -n minio media-import -- sh -c "
  mkdir -p /mnt/dst/Movies '/mnt/dst/TV Shows'
  nohup sh -c '
    echo \"[\$(date)] Starting Movies copy\" >> /tmp/rsync.log
    rsync -a --info=progress2 \"/mnt/src/Ben'\''s Data/Movies/\" /mnt/dst/Movies/ >> /tmp/rsync.log 2>&1
    echo \"[\$(date)] Movies done\" >> /tmp/rsync.log
    echo \"[\$(date)] Starting TV Shows copy\" >> /tmp/rsync.log
    rsync -a --info=progress2 \"/mnt/src/Ben'\''s Data/TV Shows/\" \"/mnt/dst/TV Shows/\" >> /tmp/rsync.log 2>&1
    echo \"[\$(date)] TV Shows done\" >> /tmp/rsync.log
    echo \"[\$(date)] ALL DONE\" >> /tmp/rsync.log
  ' > /dev/null 2>&1 &
  echo PID:\$!
"
```

### 5. Monitor progress

```bash
# Check if rsync is still running
kubectl exec -n minio media-import -- ps aux | grep rsync

# Tail the log (note: --info=progress2 output is noisy with carriage returns)
kubectl exec -n minio media-import -- tail -20 /tmp/rsync.log

# Check destination file count / size
kubectl exec -n minio media-import -- du -sh /mnt/dst/Movies '/mnt/dst/TV Shows'
```

### 6. Unmount and clean up

**Important:** unmount the source drive before deleting the pod. Killing a pod with an active FUSE mount leaves the device dirty.

```bash
kubectl exec -n minio media-import -- umount /mnt/src
kubectl delete pod media-import -n minio
```

Once the pod is deleted, safely eject/unplug the external drive.

## Initial Setup

1. Wait for ArgoCD to sync (intel-device-plugins must be ready first)
2. Access `https://jellyfin.catfish-mountain.com` (requires Tailscale connection)
3. Run the setup wizard, create admin account
4. Add media libraries pointing to `/media`
5. Configure hardware transcoding (see above)
6. Connect Infuse: Settings > Add Library > Jellyfin > enter server URL
