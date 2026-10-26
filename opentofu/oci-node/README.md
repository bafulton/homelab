# oci-node (`ocifree`)

Manually-applied OpenTofu that provisions **`ocifree`** — a free-tier OCI Ampere
A1 Talos worker (2 OCPU / 12 GB, arm64) that joins the homelab cluster over
Tailscale. Same manual-apply pattern as `opentofu/oci-forwarder`.

## Prerequisites
1. `~/.oci/config` `[DEFAULT]` (the tenancy's API signing key).
2. The boot image exists: run `./build-oci-image.sh` (idempotent; imports
   `talos-<talos/cluster.yaml version>-arm64` if missing).
3. The worker config exists at `talos/clusterconfig/homelab-ocifree.yaml`
   (gitignored; run `talos/generate-configs.sh`).

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

## Networking (two planes)
- **Management / join:** Tailscale (the node IP is the Tailscale address; the
  API endpoint is `beelink.catfish-mountain.ts.net`).
- **Pod mesh:** Tailscale subnet routes. The node runs `--accept-routes
  --snat-subnet-routes=false` and advertises its own pod `/24`, so cross-location
  pod traffic rides Tailscale directly — which handles NAT traversal, the home's
  dynamic IP, and dual-stack, and egresses on `41641/udp` (already open). No
  extra inbound port is needed. The home nodes additionally advertise their node
  `/32` so this node can reach the apiserver ClusterIP. See `talos/README.md`
  "Cross-node pod networking" and `infra/subnet-route-steering`.

## Post-join: nothing to wire up
Everything is declarative in the Talos config, so the node is reachable and its
pod routes are advertised the instant it registers — no manual step after
`tofu apply`.

Validate: the goldpinger graph (`goldpinger.catfish-mountain.com`) shows ocifree
healthy to both home nodes, and a pod on ocifree resolves CoreDNS and reaches an
off-node ClusterIP.

## Upgrades
Routine Talos/k8s upgrades are in-place via tuppr (the `metal`/installer image),
untouched by this module. Re-run `build-oci-image.sh` after a Talos bump so a
future reprovision boots a current image.
