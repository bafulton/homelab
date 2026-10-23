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
- **Pod mesh:** Kilo runs its own WireGuard for cross-location traffic, nested
  inside Tailscale. Each node's `kilo.squat.ai/force-endpoint` is its tailnet name
  (`<node>.catfish-mountain.ts.net:51820`), so Kilo's wg rides Tailscale — which
  handles NAT traversal, the home's dynamic IP, and dual-stack, and egresses on
  `41641/udp` (already open). No public Kilo port is needed, so
  `kilo_wireguard_ingress` is `false`. Kilo's MTU is 1200 to fit inside Tailscale's
  1280 tunnel (see `infra/kilo`). Both `kilo.squat.ai/location=cloud` and the
  force-endpoint are baked into the Talos config (`nodeAnnotations`), so kg is
  located *and* reachable the instant the node registers.

## Post-join: nothing to wire up
The cross-location mesh used to need a manual `force-endpoint` annotation here
(the public IP wasn't known until the instance existed). It's now declarative:
talconfig `nodeAnnotations` pins it to `ocifree.catfish-mountain.ts.net:51820`,
and because ocifree reclaims the name `ocifree` on reprovision, that value stays
correct across rebuilds with no manual step — Kilo re-resolves the name every
reconcile. The mesh comes up on its own once the node registers.

Validate: the goldpinger graph (`goldpinger.catfish-mountain.com`) shows ocifree
healthy to both home nodes, and a pod on ocifree resolves CoreDNS and reaches an
off-node ClusterIP.

## Upgrades
Routine Talos/k8s upgrades are in-place via tuppr (the `metal`/installer image),
untouched by this module. Re-run `build-oci-image.sh` after a Talos bump so a
future reprovision boots a current image.
