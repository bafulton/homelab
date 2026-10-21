# Tuppr

Automated Talos and Kubernetes upgrade orchestration.

## How It Works

Tuppr acts on two resources (`tuppr.home-operations.com/v1alpha1`), which this
chart renders from `values.yaml`:

| Resource | Name | Does |
|----------|------|------|
| `TalosUpgrade` | `talos` | Moves every node to `talosVersion`, one at a time, control plane first: health checks, drain, wait for volumes to detach, `talosctl upgrade --drain=false` (run from the other node), wait for Ready, uncordon |
| `KubernetesUpgrade` | `kubernetes` | Runs `talosctl upgrade-k8s` against the control plane: control-plane components, kube-proxy, then each kubelet. No drain, no reboot |

A version bump edits the resource in place and tuppr re-runs it. The two never
run at the same time, and a `KubernetesUpgrade` waits while a `TalosUpgrade` is
pending or running.

## Upgrade Cycle

1. **Talos PR.** Renovate bumps `talosVersion` in `talos/talconfig.yaml` and
   here. Skim the Talos release notes and
   [sbc-raspberrypi](https://github.com/siderolabs/sbc-raspberrypi) for Pi 5
   regressions, `brew upgrade siderolabs/tap/talosctl`, then merge.
2. **Talos rollout.** tuppr upgrades beelink, then rpi5.
3. **Kubernetes PR.** Renovate bumps `kubernetesVersion` in both files and
   `KUBECTL_VERSION` in `images/homelab-toolbox/Dockerfile`. Bump
   `images/homelab-toolbox/VERSION` on the PR so the image build passes. The
   `talos-k8s-compatibility` check passes once the Talos version it needs is on
   `main`. Merge.
4. **Kubernetes rollout.** tuppr runs `upgrade-k8s`.

Be around for step 2. Every Longhorn volume has its only replica on beelink,
and beelink is the only control-plane node, so its turn takes the API server
and every Longhorn-backed app down for the few minutes of drain and reboot.
rpi5's turn moves its pods to beelink and is barely noticeable.

## Gates

| Value | Renders |
|-------|---------|
| `talos.upgradeEnabled` | `TalosUpgrade` |
| `kubernetes.upgradeEnabled` | `KubernetesUpgrade` |

With a gate off, version bumps only change files, and nodes are upgraded by
hand (see "Upgrade Talos" in `talos/README.md`).

The Talos gate moves every node to `talosVersion` in either direction, so a
node running a newer version is downgraded. Set `talosVersion` to the newest
node's version before turning the gate on.

## Pausing

Set `talos.suspend` or `kubernetes.suspend` to `true` to pause an upgrade where
it stands (tuppr's `tuppr.home-operations.com/suspend` annotation), and back to
`false` to resume. Use this rather than turning a gate off, which deletes the
resource mid-run.

## Draining

`policy.waitForVolumeDetach` makes tuppr drain the node itself. Its drain gives
up after 10 minutes, uncordons the node and retries a minute later, so a drain
that cannot finish repeats rather than failing. Two settings keep the drain
finishable:

- Longhorn's `nodeDrainPolicy: allow-if-replica-is-stopped`
  (`kubernetes/infra/longhorn/values.yaml`) releases beelink's instance-manager
  PDB once its replicas stop.
- PDB-protected workloads need room on the other node for their replacement.

## Resources

- [Tuppr docs](https://tuppr.home-operations.com/)
- [Tuppr GitHub](https://github.com/home-operations/tuppr)
