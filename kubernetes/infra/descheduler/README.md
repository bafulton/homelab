# descheduler

Runs the [Kubernetes descheduler](https://github.com/kubernetes-sigs/descheduler) as a
CronJob to gently rebalance movable workloads off the over-utilized `beelink` node
toward `rpi5`.

## Why

The scheduler only places a pod once, at creation, and never migrates a running pod.
Over time this concentrates load on `beelink` (control-plane node + only Longhorn
storage node + only amd64 node), which sits near its memory ceiling. The descheduler
periodically evicts a few movable pods from the over-utilized node so the scheduler
re-homes them onto `rpi5`.

This is a **soft push**, not a pin: nothing is bound to a specific node. If `rpi5` is
full or down, everything falls back to `beelink`.

## How it's configured

Single profile, single plugin — **`LowNodeUtilization`** (see `values.yaml`). It scores
nodes by resource **requests** (not live usage) and evicts from nodes above
`targetThresholds`, letting the scheduler place them on nodes below `thresholds`.

| | CPU | Memory |
|---|-----|--------|
| `thresholds` (under → target) | 40% | 50% |
| `targetThresholds` (over → source) | 75% | 65% |

Thresholds were set against the 2026-07-21 request allocation (beelink 66%/75%,
rpi5 31%/45%) so beelink classifies as a source and rpi5 as a target. The CPU
source threshold moved from 60% to 75% on 2026-10-30, because `ocifree` (under 2
CPUs, ~860m of it fixed requests) sat at 60% and churned pods without rebalancing
anything. Re-check with `kubectl describe node <name>` (Allocated resources) if the
cluster shape changes.

## Safety rails

- **`nodeFit: true`** — a pod is only evicted if it could actually schedule elsewhere.
  This is what keeps the beelink-pinned workloads (Longhorn-PVC pods via
  Longhorn disk/node affinity, amd64-only images, static
  control-plane pods) from being churned — they have no other home, so they're left
  alone.
- **`PodsWithPVC` protection** — PVC-backed stateful pods (ClickHouse, garage,
  signoz-db, home-assistant, …) are never evicted, on top of `nodeFit`.
- **`maxNoOfPodsToEvictPerNode: 3`** — at most a few evictions per run.
- DaemonSets, mirror (static) pods, and system-critical pods are protected by the
  DefaultEvictor automatically.
- PodDisruptionBudgets are respected. Single-replica Deployments without a PDB take a
  brief restart when moved.

## Tuning levers

- **Cadence:** `descheduler.schedule` (default `*/15 * * * *`).
- **Live-usage instead of requests:** add `metricsProviders: [{source: KubernetesMetrics}]`
  under `deschedulerPolicy` to score by actual utilization (metrics-server) rather than
  requests. More responsive to real pressure, more volatile — start with requests.
- **Dry run:** set `descheduler.cmdOptions.dryRun: true` to log intended evictions
  without acting.
