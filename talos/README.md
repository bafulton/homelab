# Talos Linux Bootstrap Guide

This guide covers bootstrapping a homelab Kubernetes cluster using Talos Linux
with Tailscale for secure node-to-node communication.

## Architecture Overview

This setup creates a Kubernetes cluster where:
- Networking runs on **two planes** — a LAN data plane and a Tailscale
  control/reach plane (see [Networking model](#networking-model-two-planes))
- The control plane node also runs workloads (no taint)
- GitOps-driven via ArgoCD

Example configuration:
| Node | Role | Architecture | Hostname |
|------|------|--------------|----------|
| Mini PC | Control Plane + Worker | amd64 | beelink |
| Raspberry Pi | Worker | arm64 | rpi5 |

## Networking model (two planes)

The cluster deliberately runs on two network planes. Keeping them separate is
what lets LAN services stay fast while the cluster stays reachable — and
joinable — from anywhere.

**LAN data plane — `192.168.1.0/24`.** Carries pod-to-pod traffic (flannel,
direct over the LAN) and the LAN-facing load balancers. Each node's Kubernetes
`InternalIP` is its LAN address, because **MetalLB runs in L2 mode** and
ARP-announces its service VIPs (Traefik gateway `192.168.1.200`, time-machine
`.201`, mosquitto `.202`) on this subnet — L2/ARP only works when the speakers
hold LAN-adjacent node addresses. Set in `talconfig.yaml` via
`kubelet.nodeIP.validSubnets`, LAN subnet listed first.

**Tailscale control / reach plane — `catfish-mountain.ts.net` (`100.64.0.0/10`).**
Carries the Kubernetes API endpoint (`https://beelink.catfish-mountain.ts.net:6443`),
MagicDNS (`100.100.100.100`), and `talosctl` / `kubectl` management. Every node
runs the Tailscale system extension and also holds a `100.x` address. This plane
is what lets you:
- manage the cluster from anywhere on the tailnet with no public `6443` exposure
  and no router port-forwarding, and
- join a node that is **not** on the home LAN — how rpi5 joined while remote, and
  the foundation for adding a cloud node (see `~/Desktop/oci-node-plan.md`).

**Why both.** The two planes carry the two jobs a flat setup would conflate:
MetalLB pins the data plane to the LAN, while Tailscale provides secure
cross-network reach for management and off-LAN nodes. Neither plane can do the
other's job — a LAN-only API endpoint can't serve a remote node, and a
Tailscale-only node address breaks MetalLB L2.

**Consequence for node-mesh overlays.** Because Tailscale is a real interface on
every node, its `100.x` address is part of each node's address set. Any overlay
that tries to *be* the node mesh (e.g. Talos KubeSpan) discovers that Tailscale
address and prefers it, routing even LAN-adjacent nodes over Tailscale
(WireGuard-in-WireGuard) — measured ~130 Mbit/s vs ~910 direct on the LAN.
`filters.endpoints` doesn't prevent it (peers rebuild the endpoint from the raw
address the discovery service propagates). So cross-site connectivity for a
remote node is handled at the reach plane rather than by flattening both planes
into one mesh. Full analysis in `~/Desktop/oci-node-plan.md`.

## Local vs remote node profile

Nodes fall into two profiles. The split is deliberate — a remote cloud node has a
different failure and recovery model than a machine on the home LAN, so a few
settings flip by role. Everything in this table is **provider-agnostic** (it is
Talos-layer config); the provider-specific pieces — instance, network, custom-image
import — live in a per-provider OpenTofu module such as `opentofu/oci-node/`.

| Setting | Local node (home LAN) | Remote node (cloud) |
|---|---|---|
| `homelab.io/location` label | `local` | `remote` |
| Tailscale registration | **non-ephemeral** (`?ephemeral=false`) | **ephemeral** (default — drop the suffix) |
| kubelet `nodeIP.validSubnets` | LAN `192.168.1.0/24` + Tailscale `100.64.0.0/10` | Tailscale `100.64.0.0/10` only |
| Kilo | (home location) | `kilo.squat.ai/location: cloud`, a public `51820/udp` WireGuard endpoint, and `force-endpoint` set after join |
| `iscsi-tools` extension | yes (Longhorn storage node) | only if the node must mount Longhorn PVCs (open-iscsi is needed on any node that attaches a volume) |
| Longhorn node `allowScheduling` | `true` (holds replicas) | `false` — no replicas on an ephemeral node, set in `infra/longhorn` `nodeConfig`; `longhorn-manager` + `iscsi-tools` still run so pods here can mount PVCs whose replicas live at home |
| Provider DNS search domain | keep (home router's domain NXDOMAINs cleanly) | **strip it** at the provider — a cloud VCN search domain can SERVFAIL and break libc resolution (see below) |

**Why remote nodes are ephemeral.** A home node's disconnect is almost always a
reboot or power blip — the same machine returns, so its tailnet identity should
survive (non-ephemeral). A remote node offline for more than ~30–60 min has almost
certainly been terminated or reclaimed by the provider, and the fix is to
**provision a new one**. A non-ephemeral dead node lingers as a stale device, so
the replacement registers as `ocifree-1` and breaks the `ocifree.catfish-mountain.ts.net`
name the cluster depends on (the node IP *is* the Tailscale IP). Ephemeral means
Tailscale reaps the dead node (~30–60 min after last activity — far longer than any
routine reboot, so upgrades don't trigger it) and the replacement reclaims the name
cleanly. Set per remote node by overriding the all-nodes tailscale
`ExtensionServiceConfig` to drop the `?ephemeral=false` suffix (OAuth clients default
to ephemeral). Home nodes keep the suffix. Note: ephemeral vs non-ephemeral is fixed
at **registration**, so flipping it only takes effect on the node's next (re)join.

**Why remote nodes strip the provider DNS search domain.** A cloud provider's DHCP
hands the node a VCN search domain (OCI: `<vcn-dns-label>.oraclevcn.com`). Its internal
resolver returns **SERVFAIL** (not NXDOMAIN) for bogus names under that suffix — and
because the pod resolver uses `ndots:5`, every libc `getaddrinfo` tries
`<name>.<vcn-domain>` first, hits SERVFAIL, and aborts the whole lookup. Pods on that
node then can't resolve external names at all (git clones, healthchecks.io pings, …),
while small direct queries that skip the search list (e.g. `dig`) still work, which
makes it look intermittent. A home router's search domain NXDOMAINs instead, so libc
falls through to the bare name — which is why only remote nodes hit this. Fix it at the
source in the provider module: give the subnet a DHCP options set with the Internet+VCN
resolver but **no SearchDomain** (see `opentofu/oci-node/network.tf`), then re-lease
(reboot) once. The node leases a clean `resolv.conf` (cluster.local searches only) and
resolves like any home node. Note: Talos's `machine.network.disableSearchDomain` does
**not** fix this — it only suppresses the hostname-derived search domain, not the
explicit DHCP domain-search option the provider sends.

**Adding a remote node on a new provider (AWS, GCP, …).** The profile above is
unchanged; only two things are provider-specific: a new OpenTofu module modeled on
`opentofu/oci-node/` (instance + network + custom-image import, with that provider's
quirks — e.g. OCI needs a streamOptimized-VMDK import forced to UEFI firmware, and a
DHCP options set with no SearchDomain so pods can resolve external names), and
the platform image from Image Factory (`aws`, `gcp`, … instead of `oracle`). The
Talos profile — ephemeral, location label, Kilo cloud annotation, Tailscale-only
node IP — carries over as-is. (When the cluster migrates off the EOL talhelper to
`talosctl`-native patch files, this profile becomes a single shared remote-node
patch file rather than a per-node override.)

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
==> Found configs for: beelink rpi5

==> Scanning for Talos nodes on 192.168.1.0/24
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

Routine upgrades run through tuppr - see `kubernetes/infra/tuppr/README.md`.
To upgrade a node by hand (with tuppr's Talos gate off), upgrade the local
`talosctl` first (`brew upgrade siderolabs/tap/talosctl`).
Then drain the node exactly as for a reboot - steps 1-4 of
`scripts/safe-reboot-node.sh` (cordon, drain, wait for Longhorn volumes to
detach) - and upgrade it over its LAN IP, so the Tailscale extension restarting
mid-upgrade can't cut the connection:

```bash
talosctl -n <node-lan-ip> -e 192.168.1.86 upgrade --drain=false \
  --image factory.talos.dev/installer/<schematic-id>:vX.Y.Z
kubectl wait --for=condition=Ready node/<node> --timeout=900s
kubectl uncordon <node>
```

Keep the endpoint (`-e`) on beelink, the control-plane node: `talosctl`
fetches its kubeconfig from the endpoint, and a worker serves none.
`--drain=false` hands the drain to the `kubectl` step above. The `tuppr` pod
tolerates cordoned nodes and may stay on the node through the drain; it is
stateless, so leave it.

### Reset a node (wipe and rejoin)
```bash
talosctl reset --nodes <node>.<tailnet>.ts.net --graceful=false
```

### Safe Node Reboots (CRITICAL for Longhorn)

**⚠️ NEVER USE `talosctl reboot` DIRECTLY ON NODES WITH LONGHORN VOLUMES**

Direct reboots can cause filesystem corruption because:
- Longhorn volumes remain attached during the reboot
- Pending writes are not flushed before shutdown
- Volumes are not cleanly unmounted
- Result: XFS corruption, data loss, volumes stuck in "faulted" state

**Always use the safe reboot script:**

```bash
./scripts/safe-reboot-node.sh <node-name>

# Example
./scripts/safe-reboot-node.sh beelink
```

The script performs these steps automatically:
1. Cordons the node (prevents new pods)
2. Drains the node (evicts pods gracefully, 5-minute timeout)
3. **Waits for all Longhorn volumes to detach** (critical!)
4. Reboots the node via talosctl
5. Waits for the node to become Ready
6. Uncordons the node

#### Manual Safe Reboot Procedure

If you need to do it manually:

```bash
# 1. Cordon the node
kubectl cordon <node-name>

# 2. Drain the node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --timeout=300s --grace-period=120

# 3. CRITICAL: Verify all Longhorn volumes are detached
kubectl get volumes.longhorn.io -n longhorn -o json | \
  jq -r '.items[] | select(.spec.nodeID == "<node-name>") | .metadata.name'
# Output should be empty. If not, wait until all volumes detach.

# 4. Reboot the node
talosctl -n <node-name>.catfish-mountain.ts.net reboot

# 5. Wait for node to become Ready
kubectl wait --for=condition=Ready node/<node-name> --timeout=600s

# 6. Uncordon the node
kubectl uncordon <node-name>
```

**Why this matters:** The USB disk showing 11 unsafe shutdowns and the NVME showing 37 unsafe shutdowns in SMART data directly correlates with volume corruption. Each improper reboot risks filesystem damage.

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
