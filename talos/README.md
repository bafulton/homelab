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

- [talosctl](https://www.talos.dev/latest/introduction/getting-started/#talosctl) - `brew install siderolabs/tap/talosctl`
- [talhelper](https://budimanjojo.github.io/talhelper/latest/) - `brew install talhelper`
- [kubectl](https://kubernetes.io/docs/tasks/tools/) - `brew install kubectl`

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

Save the **Client ID** and **Client Secret** - you'll need to add these to Bitwarden Secrets Manager (see next section).

#### 4. Add OAuth Credentials to Bitwarden Secrets Manager

The Tailscale operator credentials are managed via External Secrets, pulling from Bitwarden Secrets Manager. Before running `bootstrap.sh`, you need to:

1. **Create two secrets in Bitwarden Secrets Manager:**
   - One containing the OAuth Client ID
   - One containing the OAuth Client Secret

2. **Update `kubernetes/infra/tailscale-operator/values.yaml`** with the Bitwarden secret UUIDs:
   ```yaml
   oauth:
     bitwardenSecretIds:
       clientId: "<uuid-of-client-id-secret>"
       clientSecret: "<uuid-of-client-secret-secret>"
   ```

3. **Commit and push** the values.yaml change before bootstrapping

During bootstrap, you'll also be prompted for a **Bitwarden Secrets Manager Access Token**. Create this at [Bitwarden → Secrets Manager → Machine Accounts](https://vault.bitwarden.com) with read access to the project containing your secrets.

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

### Important: Copy the Schematic ID

After configuring your image, the Image Factory will display a **schematic ID** like:
```
Your image schematic ID is: 012427dcde4d2c4eff11f55adf2f20679292fcdffb76b5700dd022c813908b07
```

**Copy this ID** - you'll need to add it to `talconfig.yaml` so Talos installs the correct image with your extensions. The schematic goes in the `talosImageURL` field for each node:

```yaml
nodes:
  - hostname: beelink
    talosImageURL: factory.talos.dev/installer/<your-schematic-id>
    # Note: Don't include the version tag - talhelper appends it automatically
```

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

Configuration uses [Talhelper](https://budimanjojo.github.io/talhelper/latest/), which generates Talos configs from a declarative `talconfig.yaml` file.

### Configure your environment

Create a `.env` file with your secrets:

```bash
cd talos/
cp .env.example .env
```

Edit `.env` to add your Tailscale auth key:
```bash
# talos/.env (git-ignored)
TS_AUTHKEY=tskey-auth-xxxxx
```

### Customize talconfig.yaml (if needed)

The `talconfig.yaml` file defines your cluster. Review and adjust:

- **Node hostnames** - Update the `nodes:` section if your hostnames differ
- **Talos/Kubernetes versions** - Update if you want specific versions
- **Patches** - Add or remove patches as needed

### Generate configs

Run the generator script:

```bash
./generate-configs.sh
```

Example output:
```
==> Loading environment from .env file

==> Using existing secrets from talsecret.yaml

==> Generating Talos configs with Talhelper

Generated configs in clusterconfig/

Install talosconfig to /Users/you/.talos/config? [Y/n] y

==> talosconfig installed and configured for beelink.catfish-mountain.ts.net

==> Config generation complete!
```

This creates:
- `clusterconfig/homelab-<hostname>.yaml` - Machine config for each node
- `clusterconfig/talosconfig` - Your talosctl client config
- `talsecret.yaml` - Cluster secrets (CA certs, keys, tokens)

**Important**: The `clusterconfig/` directory and `talsecret.yaml` contain secrets and should NOT be committed to git. Back up `talsecret.yaml` securely (e.g., password manager) - you'll need it for disaster recovery or regenerating configs.

### Adding a new node later

To add a new worker node:

1. Add the node to `talconfig.yaml`:
   ```yaml
   nodes:
     # ... existing nodes ...
     - hostname: new-node
       controlPlane: false
       ipAddress: new-node.catfish-mountain.ts.net
       installDisk: /dev/mmcblk0  # or appropriate disk
   ```

2. Regenerate configs: `./generate-configs.sh`
3. Flash and boot the new device with Talos
4. Apply the new config: `talosctl apply-config --insecure -n <ip> -f clusterconfig/homelab-new-node.yaml`

## Step 4: Boot Nodes and Apply Configs

Boot all nodes. They'll get DHCP addresses on your local network initially.

**Note:** If reinstalling on a system that previously had Talos, you'll see a boot menu:
- Select **"Talos (Reset system disk)"** to wipe the existing installation
- Then reboot and select **"Talos"** to enter maintenance mode

Run the apply script - it will scan for Talos nodes and show their MAC addresses and disks to help identify them:

```bash
./apply-configs.sh
```

Example output:
```
==> Found configs for: beelink rpi3 rpi5

==> Scanning for Talos nodes on 192.168.1.0/24
  Found: 192.168.1.51 | MAC: e4:5f:01:xx:xx:xx | Disks: mmcblk0 (32GB)
  Found: 192.168.1.52 | MAC: 2c:cf:67:xx:xx:xx | Disks: mmcblk0 (64GB)
  Found: 192.168.1.50 | MAC: dc:a6:32:xx:xx:xx | Disks: mmcblk0 (62 GB) nvme0n1 (2 TB)

==> Match nodes to configs
Which node is 'beelink'?
  [1] 192.168.1.50 | MAC: dc:a6:32:xx:xx:xx | Disks: mmcblk0 (62 GB) nvme0n1 (2 TB)
  ...
```

After applying, **remove the USB drive** and the node will reboot into Talos from the internal drive.

Wait 2-3 minutes for Tailscale to connect, then verify the node is reachable via Tailscale:

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
3. Prompt for secrets (ArgoCD admin password and Bitwarden access token)
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
talosctl logs ext-tailscale  # Tailscale extension service
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
talosctl logs ext-tailscale --nodes <node>
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
If using Longhorn, verify iSCSI is loaded (requires `iscsi-tools` extension in your Talos image):
```bash
talosctl read /proc/modules --nodes <node> | grep iscsi
```
