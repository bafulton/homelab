# Raspberry Pi 5 Talos Migration Guide

## Current State (January 2026)

The RPi5 node runs **talos-rpi5 community images (v1.11.5)** because official Talos lacks proper RPi5 support:
- Official Talos kernel missing RP1 chip drivers (ethernet, USB)
- Community project provides custom kernel with RPi5 support
- Extensions baked in: iscsi-tools, tailscale, util-linux-tools

**Tracking issues:**
- https://github.com/siderolabs/talos/issues/7978
- https://github.com/siderolabs/sbc-raspberrypi/issues/23
- https://github.com/siderolabs/talos/discussions/7821

## When Official Support Lands

Watch for:
1. Talos release notes mentioning "Raspberry Pi 5" support
2. `sbc-raspberrypi` overlay updates with RPi5 device trees
3. Kernel 6.19+ in Talos (has full RPi5 device tree support)

Test by checking if Image Factory produces working RPi5 images.

## Migration Steps

### 1. Verify Official Support Works

Before migrating, test that official Talos works on RPi5:

```bash
# Download test image with your schematic
curl -LO "https://factory.talos.dev/image/59a07420a7e77b52dce55311856a16b377e2f9ef61762e8873de65a945954d91/v1.X.X/metal-arm64.raw.zst"

# Flash to spare SD card and test boot + ethernet
```

### 2. Update talconfig.yaml

Change the RPi5 `talosImageURL` from the community image back to Image Factory:

```yaml
# Before (community image)
- hostname: rpi5
  talosImageURL: ghcr.io/talos-rpi5/installer:v1.11.5

# After (official Image Factory)
- hostname: rpi5
  talosImageURL: factory.talos.dev/installer/59a07420a7e77b52dce55311856a16b377e2f9ef61762e8873de65a945954d91
```

### 3. Regenerate Configs

```bash
cd talos
./generate-configs.sh
```

### 4. Upgrade the Node

If upgrading from v1.11.5 to v1.13+ (skipping v1.12), do it in steps:

```bash
# Step 1: Upgrade to v1.12.x first
talosctl upgrade \
  --nodes rpi5.catfish-mountain.ts.net \
  --image factory.talos.dev/installer/59a07420a7e77b52dce55311856a16b377e2f9ef61762e8873de65a945954d91:v1.12.X

# Step 2: After successful reboot, upgrade to target version
talosctl upgrade \
  --nodes rpi5.catfish-mountain.ts.net \
  --image factory.talos.dev/installer/59a07420a7e77b52dce55311856a16b377e2f9ef61762e8873de65a945954d91:v1.13.X
```

For single minor version jumps (e.g., v1.12 → v1.13), one upgrade is sufficient.

### 5. Verify

```bash
# Check node version
kubectl get nodes -o wide

# Verify Talos version
talosctl version --nodes rpi5.catfish-mountain.ts.net

# Check extensions are loaded
talosctl get extensions --nodes rpi5.catfish-mountain.ts.net
```

### 6. Update Kubernetes Version (if needed)

If the cluster Kubernetes version changed, upgrade via tuppr or manually:

```bash
talosctl upgrade-k8s --nodes rpi5.catfish-mountain.ts.net --to v1.X.X
```

## Rollback

If official images don't work, rollback to community images:

```bash
talosctl upgrade \
  --nodes rpi5.catfish-mountain.ts.net \
  --image ghcr.io/talos-rpi5/installer:v1.11.5
```

## Schematic Reference

The schematic `59a07420a7e77b52dce55311856a16b377e2f9ef61762e8873de65a945954d91` includes:
- Overlay: `siderolabs/sbc-raspberrypi` (rpi_generic)
- Extensions: iscsi-tools, tailscale, util-linux-tools

To recreate or modify, use https://factory.talos.dev/
