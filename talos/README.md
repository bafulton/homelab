# Talos Linux Bootstrap Guide

This guide covers bootstrapping a homelab Kubernetes cluster using Talos Linux
with Tailscale for secure node-to-node communication.

## Architecture Overview

This setup creates a Kubernetes cluster where:
- All nodes communicate over Tailscale (your private mesh network)
- The control plane node also runs workloads (no taint)
- GitOps-driven via ArgoCD

Example configuration:
| Node | Role | Architecture | Hostname |
|------|------|--------------|----------|
| Mini PC | Control Plane + Worker | amd64 | beelink |
| Raspberry Pi | Worker | arm64 | rpi3 |
| Raspberry Pi | Worker | arm64 | rpi5 |

## Prerequisites

- [talosctl](https://www.talos.dev/latest/introduction/getting-started/#talosctl) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm](https://helm.sh/docs/intro/install/) installed
- Tailscale auth key (create at https://login.tailscale.com/admin/settings/keys)
- Tailscale OAuth client credentials for the operator

## Step 1: Generate Images from Talos Image Factory

Go to https://factory.talos.dev and create images for each architecture you need.

### Required Extensions

| Extension | Purpose |
|-----------|---------|
| `siderolabs/tailscale` | **Required.** Establishes mesh network before Kubernetes starts. |

### Optional Extensions

| Extension | When needed |
|-----------|-------------|
| `siderolabs/iscsi-tools` | Required if using **Longhorn** for storage |
| `siderolabs/util-linux-tools` | Required if using **Longhorn** (provides `nsenter`) |
| `siderolabs/intel-ucode` | Optional. CPU microcode updates for Intel CPUs |
| `siderolabs/amd-ucode` | Optional. CPU microcode updates for AMD CPUs |

### amd64 Image (Mini PCs, NUCs, Intel/AMD machines)

1. Select Talos version (latest stable)
2. Select architecture: **amd64**
3. Select extensions (at minimum `siderolabs/tailscale`)
4. Download the appropriate image for your boot method (ISO, raw disk image, etc.)

### arm64 Image (Raspberry Pi)

1. Select Talos version (latest stable)
2. Select architecture: **arm64**
3. Select **Raspberry Pi** as the platform
4. Select extensions (at minimum `siderolabs/tailscale`)
5. Download the raw disk image for SD card flashing

## Step 2: Generate Machine Configs

Run the config generator script. It will prompt for your configuration interactively:

```bash
cd talos/
./generate-configs.sh
```

The script will prompt for:
1. **Tailnet name** - Your Tailscale network (e.g., `catfish-mountain`)
2. **Control plane hostname** - Name for your control plane node (e.g., `beelink`)
3. **Worker hostnames** - Space-separated names for worker nodes (e.g., `rpi3 rpi5`)
4. **Tailscale auth key** - Hidden input, won't appear in bash history

Example session:
```
==> Cluster Configuration
Tailscale tailnet name (e.g., catfish-mountain): catfish-mountain
Control plane node hostname (e.g., beelink): beelink
Worker node hostnames (space-separated, e.g., rpi3 rpi5): rpi3 rpi5

==> Secrets (input is hidden)
Tailscale Auth Key:

==> Configuration Summary
  Tailnet:        catfish-mountain.ts.net
  Control plane:  beelink
  Workers:        rpi3 rpi5
  Cluster endpoint: https://beelink.catfish-mountain.ts.net:6443

Proceed? [Y/n] y

==> Generating Talos configs for cluster: homelab
...

Install talosconfig to /Users/you/.talos/config? [Y/n] y

==> talosconfig installed and configured for beelink.catfish-mountain.ts.net
```

This creates:
- `generated/controlplane.yaml` - For your control plane node
- `generated/worker-<hostname>.yaml` - One per worker node
- `generated/talosconfig` - Your talosctl client config

**Note**: The `generated/` directory contains secrets and should NOT be committed to git.

## Step 3: Flash Images

Use [balenaEtcher](https://etcher.balena.io/) to flash images.

### x86/amd64 Nodes (Mini PCs, NUCs, etc.)
Flash the amd64 image to a USB drive or the internal drive using balenaEtcher.

### Raspberry Pis

#### One-time EEPROM Update (Pi 4 and Pi 5 only)

Before flashing Talos for the first time, update the Pi's bootloader firmware:

1. Open **Raspberry Pi Imager**
2. Choose OS → **Misc utility images** → **Bootloader** → **SD Card Boot**
3. Flash to a spare SD card
4. Insert SD card into the Pi and power on
5. Wait 10+ seconds - green LED blinks rapidly on success (screen shows green if HDMI connected)
6. Power off and remove the SD card

This only needs to be done **once per Pi**. Pi 3 models don't need this step.

#### Flash Talos Image

Use balenaEtcher to flash the Talos arm64 image to your SD cards.

## Step 4: Boot Nodes and Apply Configs

Boot all nodes. They'll get DHCP addresses on your local network initially.

Find the nodes on your network:
```bash
talosctl disks --insecure --nodes 192.168.x.x
```

Apply configs (use local LAN IPs for initial config, since Tailscale isn't up yet):

```bash
# Control plane node
talosctl apply-config --insecure \
  --nodes <CONTROL_PLANE_LAN_IP> \
  --file generated/controlplane.yaml

# Worker nodes (repeat for each)
talosctl apply-config --insecure \
  --nodes <WORKER_LAN_IP> \
  --file generated/worker-<hostname>.yaml
```

Nodes will reboot and Tailscale will come up.

**Tip**: The `generate-configs.sh` script prints the exact commands with your hostnames at the end.

## Step 5: Bootstrap the Cluster

Run this **once** to initialize the Kubernetes cluster:

```bash
talosctl bootstrap
```

Wait for the cluster to come up:
```bash
talosctl health
```

## Step 6: Get Kubeconfig

```bash
talosctl kubeconfig -f ~/.kube/config
```

Verify cluster access:
```bash
kubectl get nodes
```

You should see all your nodes in Ready state.

## Step 7: Bootstrap GitOps

Run the bootstrap script to set up ArgoCD and start syncing infrastructure:

```bash
./bootstrap.sh
```

The script will:
1. Prompt for secrets (ArgoCD admin password, Tailscale OAuth credentials)
2. Create the required Kubernetes secrets
3. Install ArgoCD via Helm
4. Apply the root GitOps application
5. Verify the deployment

Once complete, ArgoCD will begin syncing your infrastructure. Access the UI via Tailscale:
- `https://argocd.<TAILNET>.ts.net`
- Username: `admin`
- Password: (what you entered during bootstrap)

---

## Maintenance Commands

### Check node status
```bash
talosctl health
talosctl services
```

### View logs
```bash
talosctl logs kubelet
talosctl logs tailscale
```

### Upgrade Talos
```bash
talosctl upgrade --image factory.talos.dev/installer/[your-image-id]:vX.Y.Z
```

### Reset a node (wipe and rejoin)
```bash
talosctl reset --nodes <NODE>.<TAILNET>.ts.net --graceful=false
```

---

## Differences from DietPi/K3s Setup

| Aspect | DietPi + K3s | Talos |
|--------|--------------|-------|
| SSH access | Yes | No (API only via talosctl) |
| Package manager | apt | None (immutable OS) |
| Kubernetes dist | K3s | Upstream Kubernetes |
| Config method | Shell scripts | Declarative YAML |
| Updates | apt upgrade + k3s upgrade | talosctl upgrade |
| Kubeconfig path | /etc/rancher/k3s/k3s.yaml | Via talosctl kubeconfig |

## Troubleshooting

### Tailscale not connecting
```bash
talosctl logs tailscale --nodes <node>
```

### Kubernetes API unreachable
Make sure you're using the Tailscale hostname/IP, not the LAN IP:
```bash
talosctl config endpoint <CONTROL_PLANE>.<TAILNET>.ts.net
```

### Node not joining cluster
Check kubelet logs:
```bash
talosctl logs kubelet --nodes <node>
```

### Longhorn issues
If using Longhorn, verify iSCSI is loaded (requires `iscsi-tools` extension and uncommenting kernel module in patches):
```bash
talosctl read /proc/modules --nodes <node> | grep iscsi
```
