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
- Tailscale auth key (create at https://login.tailscale.com/admin/settings/keys)
- Tailscale OAuth client credentials (for the in-cluster operator)

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

Use [balenaEtcher](https://etcher.balena.io/) to flash images to SD cards or USB drives.

### Raspberry Pi 4/5: One-time EEPROM Update

Before flashing Talos, update the bootloader firmware using **Raspberry Pi Imager**:

1. Choose OS → **Misc utility images** → **Bootloader** → **SD Card Boot**
2. Flash to an SD card, insert into Pi, and power on
3. Wait 10+ seconds - green LED blinks rapidly on success
4. Power off and remove the SD card

This is only needed once per Pi. Pi 3 models can skip this.

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

Run the bootstrap script to initialize the cluster and set up GitOps:

```bash
./bootstrap.sh
```

The script will:
1. Bootstrap the Talos cluster (`talosctl bootstrap`)
2. Retrieve and install kubeconfig
3. Prompt for secrets (ArgoCD admin password, Tailscale OAuth credentials)
4. Create the required Kubernetes secrets
5. Install ArgoCD via Helm
6. Apply the root GitOps application
7. Verify the deployment

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
