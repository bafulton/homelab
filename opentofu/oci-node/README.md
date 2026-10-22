# oci-node (`ocifree`)

Manually-applied OpenTofu that provisions **`ocifree`** — a free-tier OCI Ampere
A1 Talos worker (2 OCPU / 12 GB, arm64) that joins the homelab cluster over
Tailscale. Same manual-apply pattern as `opentofu/oci-forwarder`.

## Prerequisites
1. `~/.oci/config` `[DEFAULT]` (the tenancy's API signing key).
2. The boot image exists: run `./build-oci-image.sh` (idempotent; imports
   `talos-<talconfig version>-arm64` if missing).
3. The worker config exists at `talos/clusterconfig/homelab-ocifree.yaml`
   (gitignored; derived from rpi5's live config — see `~/Desktop/oci-node-plan.md`).

## Apply
```sh
source ./env.sh        # exports TF_VAR_compartment_ocid from ~/.oci/config
tofu init
tofu plan
tofu apply
```
This launches the A1 instance; Talos boots from the image, the tailscale
extension connects, and the node joins via the beelink API endpoint and goes
`Ready` as a `homelab.io/location=remote` worker.

## Networking (two planes + Kilo "Fix B")
- **Management / join:** Tailscale (the node IP is the Tailscale address; the
  API endpoint is `beelink.catfish-mountain.ts.net`).
- **Pod mesh:** Kilo runs its **own** WireGuard directly over the internet
  (`51820/udp`, opened by `kilo_wireguard_ingress=true`) — the way Kilo is
  designed to attach a cloud node. It is **not** tunneled inside Tailscale
  (that would be double-WireGuard with a 1280-MTU trap). `kilo.squat.ai/location=cloud`
  is baked into the Talos config so kg is located the instant the node registers.

## Post-join steps (step 6: wire up the cross-location mesh)
The one thing that can't be baked is Kilo's `force-endpoint`, because the public
IP isn't known until the instance exists (and OCI reserved-IP-in-user_data forms
a tofu dependency cycle). After the node is `Ready`:
```sh
IP=$(tofu output -raw public_ip)
kubectl annotate node ocifree \
  kilo.squat.ai/force-endpoint="$IP:51820" \
  kilo.squat.ai/persistent-keepalive="25" --overwrite
```
The ephemeral public IP is stable across reboots; re-run this only if the
instance is terminated/recreated. Then validate: a pod on ocifree resolves
CoreDNS and reaches an off-node ClusterIP.

(Until `force-endpoint` is set, kg will mesh ocifree over its Tailscale address
at the wrong MTU — harmless, since no workloads consume cross-location pod
traffic yet, and kg reconciles the moment the annotation lands. For a strictly
zero-window bring-up, gate the kg DaemonSet with nodeAffinity on a label added
only after the annotation.)

## Upgrades
Routine Talos/k8s upgrades are in-place via tuppr (the `metal`/installer image),
untouched by this module. Re-run `build-oci-image.sh` after a Talos bump so a
future reprovision boots a current image.
