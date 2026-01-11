# Time Machine Backup Server

Network-accessible Time Machine backup destination for macOS, using Samba with Apple-specific extensions.

## Overview

| | |
|---|---|
| **Storage** | Longhorn NVMe (1.8TB) |
| **Protocol** | SMB3 with vfs_fruit |
| **Discovery** | mDNS via mdns-advertiser |
| **Access** | MetalLB IP: 192.168.0.201 |

## Architecture

```
MacBook ──► mDNS: "Where's Time Machine?"
                    │
                    ▼
         ┌─────────────────────┐
         │   mDNS Advertiser   │
         │ timemachine.local   │
         │  → 192.168.0.201    │
         └─────────────────────┘
                    │
MacBook ──► SMB: Connect to 192.168.0.201
                    │
                    ▼
         ┌─────────────────────┐
         │  MetalLB: .201      │
         └─────────┬───────────┘
                   │
                   ▼
         ┌─────────────────────┐
         │   Time Machine Pod  │
         │   (Samba + fruit)   │
         │                     │
         │  /opt/time-machine/ │
         │    ├── ben/         │
         │    └── emilie/      │
         └─────────┬───────────┘
                   │
                   ▼
         ┌─────────────────────┐
         │  Longhorn NVMe PVC  │
         │      1.8 TB         │
         └─────────────────────┘
```

## Users

Each user gets their own SMB share with a quota:

| User | Share | Quota |
|------|-------|-------|
| ben | `/opt/time-machine/ben` | 900 GB |
| emilie | `/opt/time-machine/emilie` | 900 GB |

Passwords are stored in Bitwarden and synced via External Secrets.

## Connecting from macOS

### Automatic (mDNS)

1. Open Finder → Network
2. Click "Time Machine" (or "timemachine")
3. Click "Connect As..." and enter credentials
4. Open System Settings → General → Time Machine
5. Add the mounted share as a backup destination

### Manual

1. Finder → Go → Connect to Server (⌘K)
2. Enter: `smb://192.168.0.201`
3. Authenticate with your username/password
4. Add to Time Machine in System Settings

## Technical Details

### Samba Configuration

- **Protocol**: SMB3 (required for Time Machine)
- **VFS Modules**: `catia fruit streams_xattr`
- **Quotas**: Enforced via `fruit:time machine max size`
- **Model**: Advertises as `TimeCapsule8,119`

### Key smb.conf Settings

```ini
[global]
vfs objects = catia fruit streams_xattr
fruit:aapl = yes
fruit:model = TimeCapsule8,119
fruit:time machine = yes

[ben]
fruit:time machine max size = 900G
```

### Dependencies

- **mdns-advertiser**: Publishes `timemachine.local` for discovery
- **MetalLB**: Provides stable IP (192.168.0.201)
- **Longhorn**: NVMe storage backend
- **External Secrets**: Syncs passwords from Bitwarden

## Troubleshooting

### Can't find Time Machine in Finder

1. Check mDNS advertiser is running: `kubectl get pods -n mdns-advertiser`
2. Verify MetalLB assigned the IP: `kubectl get svc -n time-machine`
3. Try connecting directly: `smb://192.168.0.201`

### Authentication fails

1. Verify the secret exists: `kubectl get secret time-machine-credentials -n time-machine`
2. Check External Secrets sync: `kubectl get externalsecret -n time-machine`
3. Verify password in Bitwarden matches

### Backup fails or is slow

1. Check pod logs: `kubectl logs -n time-machine -l app.kubernetes.io/name=time-machine`
2. Verify storage: `kubectl get pvc -n time-machine`
3. Check Longhorn volume health in Longhorn UI
