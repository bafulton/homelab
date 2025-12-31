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

### Local Tools

- [talosctl](https://www.talos.dev/latest/introduction/getting-started/#talosctl) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed

### Tailscale Setup

You'll need two sets of credentials from Tailscale:

1. **Auth Key** - For nodes to join your tailnet at the OS level
2. **OAuth Client** - For the in-cluster Tailscale Operator to manage services

#### 1. Create an Auth Key

Go to [Tailscale Admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys) and create an auth key:

- **Reusable**: Yes (so you can use it for multiple nodes)
- **Ephemeral**: No (nodes should persist in your tailnet)
- **Tags**: Add a tag like `tag:k8s-node` (you'll need to define this in ACLs first)

Save this key - you'll enter it during `generate-configs.sh`.

#### 2. Configure ACLs

Go to [Tailscale Admin → Access Controls](https://login.tailscale.com/admin/acls/file) and ensure you have the required tags and SSH rules. Minimal example:

```jsonc
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:k8s-node": []
  },
  "grants": [
    {
      "src": ["*"],
      "dst": ["*"],
      "ip": ["*"]
    }
  ],
  "ssh": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:k8s-node"],
      "users": ["root"]
    }
  ]
}
```

- `tag:k8s-node` - Applied to cluster nodes via the auth key
- `tag:k8s-operator` - Used by the in-cluster operator's OAuth client
- `tag:k8s` - Owned by the operator, applied to services it exposes

#### 3. Create OAuth Client Credentials

Go to [Tailscale Admin → Settings → OAuth clients](https://login.tailscale.com/admin/settings/oauth) and create a new OAuth client:

- **Description**: Something like "Kubernetes Operator"
- **Tags**: Select `tag:k8s-operator` (devices created by the operator will get this tag)
- **Scopes**: The operator needs write access to create devices

Save the **Client ID** and **Client Secret** - you'll enter these during `bootstrap.sh`.

## Step 1: Generate and Download Images from Talos Image Factory

Go to https://factory.talos.dev and create and download an image for each device architecture in your cluster.

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

## Step 2: Flash Images

Use [balenaEtcher](https://etcher.balena.io/) to flash Talos images.

### Raspberry Pi (and other SBCs)

1. Download the **raw disk image** (`.raw.xz`) from Image Factory
2. Flash directly to the SD card with balenaEtcher
3. Insert the SD card and boot - Talos runs from the SD card

**Pi 4/5 only:** Update the bootloader firmware first (one-time):
1. Open **Raspberry Pi Imager**
2. Choose OS → **Misc utility images** → **Bootloader** → **SD Card Boot**
3. Flash to an SD card, insert into Pi, power on
4. Wait 10+ seconds - green LED blinks rapidly on success
5. Power off, remove SD card, then flash Talos

Pi 3 models can skip the EEPROM update.

### PCs (Mini PCs, NUCs, servers)

For PCs with internal drives (NVMe, SSD), use the ISO to boot and install:

1. Download the **ISO** from Image Factory
2. Flash the ISO to a USB drive with balenaEtcher

When you boot from the USB in Step 4, Talos will run in maintenance mode. After applying configs, it installs to the internal drive and reboots - then you can remove the USB.

Talos should automatically detect the correct install disk. If for some reason you need to manually specify the install disk, you can add this to your patch:
```yaml
machine:
  install:
    disk: /dev/nvme0n1  # adjust for your hardware
```

## Step 3: Generate Machine Configs

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

**Important**: The `generated/` directory contains secrets and should NOT be committed to git. However, you should back up these files securely (e.g., password manager, encrypted backup) - you'll need them for disaster recovery or adding nodes later.

## Step 4: Boot Nodes and Apply Configs

Boot all nodes. They'll get DHCP addresses on your local network initially.

Run the apply script - it will scan for Talos nodes and show their MAC addresses to help identify them:

```bash
./apply-configs.sh
```

Example output:
```
==> Scanning for Talos nodes on 192.168.1.0/24
  Found: 192.168.1.50 | MAC: dc:a6:32:xx:xx:xx | Disks: /dev/nvme0n1 (256GB)
  Found: 192.168.1.51 | MAC: e4:5f:01:xx:xx:xx | Disks: /dev/mmcblk0 (32GB)
  Found: 192.168.1.52 | MAC: 2c:cf:67:xx:xx:xx | Disks: /dev/mmcblk0 (64GB)

==> Match nodes to configs
Which node is 'controlplane'?
  [1] 192.168.1.50 | MAC: dc:a6:32:xx:xx:xx | Disks: /dev/nvme0n1 (256GB)
  ...
```

Nodes will reboot and Tailscale will come up. Wait 2-3 minutes, then verify nodes are reachable via Tailscale:

```bash
talosctl health
```

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
- `https://argocd.<tailnet>.ts.net`
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
talosctl reset --nodes <node>.<tailnet>.ts.net --graceful=false
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
talosctl config endpoint <controlplane>.<tailnet>.ts.net
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
