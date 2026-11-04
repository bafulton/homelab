# Tuppr

Automated Talos and Kubernetes upgrade orchestration.

## How It Works

Tuppr acts on two resources (`tuppr.home-operations.com/v1alpha1`), which this
chart renders from `values.yaml`:

| Resource | Name | Does |
|----------|------|------|
| `TalosUpgrade` | `talos` | Moves every node to `talosVersion`, one at a time, workers before the control plane: health checks, then `talosctl upgrade` (run from another node), which drains, reboots, waits for Ready and uncordons |
| `KubernetesUpgrade` | `kubernetes` | Runs `talosctl upgrade-k8s` against the control plane: control-plane components, kube-proxy, then each kubelet. No drain, no reboot |

A version bump edits the resource in place and tuppr re-runs it. The two never
run at the same time, and a `KubernetesUpgrade` waits while a `TalosUpgrade` is
pending or running.

## Upgrade Cycle

1. **Talos PR.** Renovate bumps `talosVersion` in `talos/cluster.yaml` and
   here. Skim the Talos release notes and
   [sbc-raspberrypi](https://github.com/siderolabs/sbc-raspberrypi) for Pi 5
   regressions, `brew upgrade siderolabs/tap/talosctl`, then merge.
2. **Talos rollout.** tuppr upgrades the workers, then beelink. The 2026-11-04
   rollout went ocifree, rpi5, beelink.
3. **Kubernetes PR.** Renovate bumps `kubernetesVersion` in both files and
   `KUBECTL_VERSION` in `images/homelab-toolbox/Dockerfile`. Bump
   `images/homelab-toolbox/VERSION` on the PR so the image build passes. The
   `talos-k8s-compatibility` check passes once the Talos version it needs is on
   `main`. Merge.
4. **Kubernetes rollout.** tuppr runs `upgrade-k8s`.

Be around for step 2. Beelink is the only control-plane node and hosts the
strict-local state volumes, so its reboot takes the API server and those apps
down. Config volumes keep a second replica on rpi5. Workloads pinned to
beelink may need to be scaled down through GitOps before its drain; check the
live pod placement and PDBs before merging the Talos PR. rpi5's turn moves
its pods to beelink, which then pulls their images.

### Pace the disruptive steps

etcd and containerd share beelink's NVMe EPHEMERAL partition (`/var`). Before
the 2026-11-04 migration they shared the eMMC, which saturated under a burst
of image pulls and caused API server instability on 2026-10-26. Keep the
rollouts paced while the new NVMe baseline is established:

- Run one disruptive change at a time: a Talos rollout, a Kubernetes rollout,
  a node reboot, or a batch of chart bumps that replace many images.
- After each, wait until beelink settles before starting the next: every pod
  Running, and beelink's NVMe busy time back near idle in SigNoz
  (`system.disk.io_time`, device `nvme0n1`).
- Merge Renovate's chart bumps in small groups rather than all at once, and
  not while a node is draining or rebooting.
- When rpi5 has to go down, expect its pods to land on beelink and pull
  images there; avoid stacking another change on top until they are Running.

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

`talosctl upgrade` does the drain: tuppr runs it with the control plane as
its endpoint, which is where it fetches the kubeconfig. It evicts in parallel
and retries PDB-refused evictions until `policy.drainTimeout` (10m), then fails
the upgrade without rebooting.

Leave tuppr's own drain (`policy.waitForVolumeDetach`, `spec.drain`) off. In
tuppr 0.5.9 it gives up at the first PDB-refused eviction, uncordons and
retries a minute later - and Longhorn's instance-manager PDB always refuses
until the pods using the node's volumes are gone, so it loops, evicting pods
each round.

The drain finishes because:

- Longhorn's `nodeDrainPolicy: allow-if-replica-is-stopped`
  (`kubernetes/infra/longhorn/values.yaml`) releases beelink's instance-manager
  PDB once its replicas stop.
- PDB-protected workloads have room on the other node for their replacement.

## Resources

- [Tuppr docs](https://tuppr.home-operations.com/)
- [Tuppr GitHub](https://github.com/home-operations/tuppr)
