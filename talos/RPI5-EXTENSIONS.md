# RPi5 Extensions - Building Custom Images

This document details how to add system extensions (iscsi-tools, tailscale, util-linux-tools) to the Raspberry Pi 5 running Talos via the talos-rpi5 community project.

## Current Status

- **RPi5 is joined to the cluster** running Talos v1.11.5-1-gfe840f161 via talos-rpi5
- **Extensions are installed**: iscsi-tools, tailscale, util-linux-tools
- **Longhorn storage is functional** on rpi5
- **Tailscale extension** is installed (requires auth key configuration to activate)

## The Challenge

Extensions cannot be added via `talosctl upgrade` due to efivarfs limitations on RPi5:

```
Firmware does not support SetVariableRT. Can not remount with rw
Error: failed to install bootloader: failed to create efivarfs reader/writer: invalid argument
```

This is a fundamental limitation of how RPi5's U-Boot handles EFI variables at runtime. The solution is to build a fresh metal image with extensions baked in, then flash the SD card.

## Working Solution: Build on RPi5 Itself

The key insight: run the imager as a privileged pod on the rpi5 node itself. This solves two problems:
1. Native arm64 execution (no cross-compilation issues)
2. Access to loopback devices (which don't work in Docker Desktop on macOS)

### Step 1: Deploy the Builder Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: talos-image-builder
  namespace: longhorn  # or any namespace with privileged access
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: rpi5
  initContainers:
  - name: builder
    image: ghcr.io/talos-rpi5/imager:v1.11.5-1-gfe840f161
    args:
    - metal
    - --arch=arm64
    - --overlay-image=ghcr.io/talos-rpi5/sbc-raspberrypi5:7d04484-v1.11.0-1-g34f19c2
    - --overlay-name=rpi5
    - --system-extension-image=ghcr.io/siderolabs/iscsi-tools:v0.2.0
    - --system-extension-image=ghcr.io/siderolabs/tailscale:1.88.1
    - --system-extension-image=ghcr.io/siderolabs/util-linux-tools:2.41.1
    - --output-kind=image
    securityContext:
      privileged: true
    volumeMounts:
    - name: dev
      mountPath: /dev
    - name: output
      mountPath: /out
  containers:
  - name: server
    image: python:3.12-alpine
    command: ["python3", "-m", "http.server", "8080", "--directory", "/out"]
    ports:
    - containerPort: 8080
    volumeMounts:
    - name: output
      mountPath: /out
  volumes:
  - name: dev
    hostPath:
      path: /dev
  - name: output
    emptyDir:
      sizeLimit: 4Gi
```

### Step 2: Wait for Build and Download

```bash
# Watch the build progress
kubectl logs talos-image-builder -n longhorn -c builder -f

# Once complete, download via port-forward
kubectl port-forward pod/talos-image-builder -n longhorn 8080:8080 &
curl -o metal-arm64-rpi5-ext.raw.zst http://localhost:8080/metal-arm64.raw.zst
kill %1

# Clean up
kubectl delete pod talos-image-builder -n longhorn
```

### Step 3: Flash and Configure

```bash
# Decompress
zstd -d metal-arm64-rpi5-ext.raw.zst

# Flash to SD card (replace diskN with your SD card)
sudo diskutil unmountDisk /dev/diskN
sudo dd if=metal-arm64-rpi5-ext.raw of=/dev/rdiskN bs=4M status=progress

# Boot rpi5, then apply config
talosctl apply-config --insecure --nodes 192.168.0.17 \
  --file talos/clusterconfig/homelab-rpi5.yaml
```

### Step 4: Restart Longhorn Pods

After applying config, Longhorn pods may be in crashloop from before extensions existed:

```bash
kubectl delete pods -n longhorn --field-selector spec.nodeName=rpi5
```

### Step 5: Verify

```bash
# Check extensions
talosctl get extensions --nodes 192.168.0.17

# Check Longhorn node
kubectl get nodes.longhorn.io -n longhorn

# Check services
talosctl services --nodes 192.168.0.17 | grep ext
```

## What Doesn't Work

### talosctl upgrade

Any attempt to upgrade with a custom installer image fails with the efivarfs error. This includes:
- Standard imager with `--base-installer-image`
- talos-rpi5 imager with `--overlay-image`
- Staged upgrades with `--stage`

### Building on macOS Docker Desktop

Docker Desktop on macOS doesn't support loopback devices properly:
```
failed to format partition /dev/loop0p1: mkfs.vfat: unable to open /dev/loop0p1
```

### Cross-Architecture Build on amd64

Building arm64 images on an amd64 node fails because the overlay installer is arm64:
```
failed to run overlay installer: fork/exec ...: exec format error
```

## Extension Versions for Talos v1.11.5

| Extension | Version |
|-----------|---------|
| iscsi-tools | v0.2.0 |
| tailscale | 1.88.1 |
| util-linux-tools | 2.41.1 |

## Image References

| Component | Image |
|-----------|-------|
| Imager | ghcr.io/talos-rpi5/imager:v1.11.5-1-gfe840f161 |
| Overlay | ghcr.io/talos-rpi5/sbc-raspberrypi5:7d04484-v1.11.0-1-g34f19c2 |

## Configuring Tailscale Extension

The tailscale extension requires an auth key. Add to machine config:

```yaml
machine:
  pods:
    - apiVersion: v1
      kind: Secret
      metadata:
        name: tailscale-auth
        namespace: kube-system
      stringData:
        TS_AUTHKEY: "tskey-auth-..."
```

Or use ExtensionServiceConfig (if supported by your Talos version).

## References

- talos-rpi5 project: https://github.com/talos-rpi5
- talos-rpi5 builder: https://github.com/talos-rpi5/talos-builder
- RPi5 support discussion: https://github.com/siderolabs/talos/discussions/7821
- Installation guide: https://rcwz.pl/2025-10-04-installing-talos-on-raspberry-pi-5/
- Official RPi5 overlay issue: https://github.com/siderolabs/sbc-raspberrypi/issues/23
