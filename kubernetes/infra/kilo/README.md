# kilo

[Kilo](https://kilo.squat.ai/) WireGuard overlay in **flannel-compatibility (add-on)
mode** — the zone-aware way to attach an off-LAN node (e.g. the planned `ocifree`
cloud node) to this cluster without degrading home LAN performance.

## Why Kilo (and not KubeSpan)

The cluster runs a deliberate two-plane network (see `talos/README.md` →
"Networking model"): a LAN data plane (flannel + MetalLB) and a Tailscale
control/reach plane. A flat node mesh like **KubeSpan can't be kept off
Tailscale** here — because `tailscale0` is a real interface on every node, its
`100.x` address propagates via the discovery service and peers rebuild it into a
WireGuard endpoint regardless of `filters.endpoints`, so even the beelink↔rpi5
LAN pair gets routed over Tailscale (wire-in-wire, ~130 Mbit/s vs ~910 on the
LAN). Full analysis in `~/Desktop/oci-node-plan.md`.

Kilo is **location-aware**: with `--local=false` it leaves intra-location
networking to flannel (home nodes stay on the LAN) and builds WireGuard links
**only across locations** (home ↔ cloud). That matches the two-plane design
instead of fighting it.

## How it's wired

- `--cni=false --compatibility=flannel` — Kilo does **not** manage pod CNI/IPAM
  or write `/etc/cni/net.d`; flannel keeps full ownership, so Talos's
  flannel-manifest reconciliation is never touched.
- `--local=false` — no WireGuard between same-location nodes; flannel/LAN carries
  that traffic. Kilo meshes only between locations.
- **Talos adaptation:** the stock Kilo manifest mounts a kubeconfig from the
  `kube-proxy` ConfigMap (a kubeadm convention Talos doesn't provide). We drop
  `--kubeconfig` entirely — `kg` then falls back to the in-cluster
  `kilo` ServiceAccount. That SA + its ClusterRole/Binding are in `rbac.yaml`.
- Runs in **kube-system**, which Talos exempts from PodSecurity (flannel and
  kube-proxy already run privileged/hostNetwork there), so the privileged
  DaemonSet needs no namespace label.
- WireGuard itself is in the Talos kernel already (KubeSpan uses it too).

## Location & endpoint config (applied to nodes, not here)

Kilo groups nodes by the `kilo.squat.ai/location` annotation and learns
cross-location endpoints from `kilo.squat.ai/force-endpoint`. These are **node**
annotations applied after a node joins, e.g.:

```sh
kubectl annotate node beelink rpi5 kilo.squat.ai/location=home
kubectl annotate node ocifree kilo.squat.ai/location=cloud
kubectl annotate node ocifree kilo.squat.ai/force-endpoint=<reachable-ip>:51820
```

With every node in a single location (`home`), Kilo builds no cross-location
links and is effectively inert for routing — which is exactly the state for the
initial coexistence test.

## Staged rollout (see `values.yaml`)

`nodeSelector` restricts `kg` to **rpi5** for the first coexistence test, so the
control-plane node (beelink) is untouched while we confirm Kilo coexists with
flannel on Talos and the home LAN still runs ~910 Mbit/s. Widen to all nodes by
setting `nodeSelector: {}` once rpi5 is verified healthy.

**Rollback** is a `git revert` of the app (ArgoCD self-heals, so don't
`kubectl delete` — revert the commit). Because `--cni=false` leaves flannel
untouched, removing Kilo leaves the LAN data plane exactly as it was.
