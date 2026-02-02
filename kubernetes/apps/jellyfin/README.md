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

| PVC | Size | Storage Class | Backup |
|-----|------|---------------|--------|
| `jellyfin-config` | 5Gi | longhorn-emmc | Daily (5 retained) |
| `jellyfin-media` | 1Ti | longhorn-usb | No (too large) |

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

## Copying Media

Use kubectl cp to transfer media into the PVC:

```bash
# Create temporary pod with media volume
kubectl run media-copy -n jellyfin --rm -it \
  --image=alpine \
  --overrides='{"spec":{"containers":[{"name":"media-copy","image":"alpine","stdin":true,"tty":true,"volumeMounts":[{"name":"media","mountPath":"/media"}]}],"volumes":[{"name":"media","persistentVolumeClaim":{"claimName":"jellyfin-media"}}]}}'

# In another terminal, copy files
kubectl cp /path/to/Movies media-copy:/media/Movies -n jellyfin
kubectl cp /path/to/TV\ Shows media-copy:/media/TV\ Shows -n jellyfin
```

## Initial Setup

1. Wait for ArgoCD to sync (intel-device-plugins must be ready first)
2. Access `https://jellyfin.catfish-mountain.com` (requires Tailscale connection)
3. Run the setup wizard, create admin account
4. Add media libraries pointing to `/media`
5. Configure hardware transcoding (see above)
6. Connect Infuse: Settings > Add Library > Jellyfin > enter server URL
