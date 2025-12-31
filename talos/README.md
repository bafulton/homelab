# Talos Linux Bootstrap Guide

This guide covers bootstrapping a homelab Kubernetes cluster using Talos Linux
with Tailscale for secure node-to-node communication.

## Architecture Overview

This setup creates a Kubernetes cluster where:
- All nodes communicate over Tailscale (your private mesh network)
- The control plane node also runs workloads (no taint)
- Longhorn-ready with iSCSI support
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

Go to https://factory.talos.dev and create two images:

### amd64 Image (Mini PCs, NUCs, Intel/AMD machines)

1. Select Talos version (latest stable)
2. Select architecture: **amd64**
3. Select extensions:
   - `siderolabs/tailscale`
   - `siderolabs/iscsi-tools`
   - `siderolabs/util-linux-tools`
   - `siderolabs/intel-ucode` (if Intel CPU) or `siderolabs/amd-ucode` (if AMD CPU)
4. Download the appropriate image for your boot method (ISO, raw disk image, etc.)

### arm64 Image (Raspberry Pi)

1. Select Talos version (latest stable)
2. Select architecture: **arm64**
3. Select **Raspberry Pi** as the platform
4. Select extensions:
   - `siderolabs/tailscale`
   - `siderolabs/iscsi-tools`
   - `siderolabs/util-linux-tools`
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

Proceed? [Y/n]
```

This creates:
- `generated/controlplane.yaml` - For your control plane node
- `generated/worker-<hostname>.yaml` - One per worker node
- `generated/talosconfig` - Your talosctl client config

**Note**: The `generated/` directory contains secrets and should NOT be committed to git.

## Step 3: Flash Images

### x86/amd64 Nodes (Mini PCs, NUCs, etc.)
Flash the amd64 image to a USB drive or the internal drive.

### Raspberry Pis
Flash the arm64 image to SD cards:
```bash
# On macOS
sudo dd if=talos-arm64-rpi.img of=/dev/diskN bs=4M status=progress
```

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

## Step 5: Configure talosctl

```bash
# Set up your talosctl config
cp generated/talosconfig ~/.talos/config

# Update endpoints to use Tailscale (replace with your control plane hostname and tailnet)
talosctl config endpoint <CONTROL_PLANE>.<TAILNET>.ts.net
talosctl config node <CONTROL_PLANE>.<TAILNET>.ts.net
```

## Step 6: Bootstrap the Cluster

Run this **once** on the control plane node:

```bash
talosctl bootstrap
```

Wait for the cluster to come up:
```bash
talosctl health
```

## Step 7: Get Kubeconfig

```bash
talosctl kubeconfig -f ~/.kube/config
```

Verify cluster access:
```bash
kubectl get nodes
```

You should see all your nodes in Ready state.

## Step 8: Create Pre-Bootstrap Secrets

Before ArgoCD syncs the infrastructure, create the required secrets:

```bash
# ArgoCD admin password
ARGOCD_PASSWORD="your-argocd-admin-password"
ARGOCD_PASSWORD_HASH=$(htpasswd -nbBC 10 "" "$ARGOCD_PASSWORD" | tr -d ':\n')

kubectl create namespace argocd
kubectl create secret generic argocd-secret \
  -n argocd \
  --from-literal=admin.password="$ARGOCD_PASSWORD_HASH" \
  --from-literal=admin.passwordMtime="$(date +%FT%T%Z)"

# Tailscale Operator OAuth credentials
kubectl create namespace tailscale
kubectl create secret generic operator-oauth \
  -n tailscale \
  --from-literal=client_id="your-ts-client-id" \
  --from-literal=client_secret="your-ts-client-secret"
```

## Step 9: Bootstrap GitOps

```bash
cd ../kubernetes/

# Add Helm repos
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

# Build and install ArgoCD
helm dependency update infra/argocd
helm install argocd infra/argocd -n argocd

# Wait for ArgoCD to be ready
kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=5m
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

# Apply the root application (this triggers all other infra)
kubectl apply -f applications.yaml
```

## Step 10: Verify Everything

```bash
# Check all nodes
kubectl get nodes -o wide

# Check ArgoCD applications
kubectl get applications -n argocd

# Check pods across namespaces
kubectl get pods -A
```

Access ArgoCD UI via Tailscale once the ingress is ready:
- `https://argocd.<TAILNET>.ts.net`

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
Verify iSCSI is loaded:
```bash
talosctl read /proc/modules --nodes <node> | grep iscsi
```
