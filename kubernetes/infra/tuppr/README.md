# Tuppr

Automated Talos and Kubernetes upgrade orchestration.

## How It Works

Tuppr watches for `TalosUpgrade` and `KubernetesUpgrade` resources
(`tuppr.home-operations.com/v1alpha1`) and upgrades nodes one at a time, with
health checks between each.

This chart renders one of each from `values.yaml`, named after the target
version (e.g. `kubernetes-upgrade-v1-36-2`), so a version bump creates a new
resource and tuppr acts on it.

## Usage

1. Renovate opens a PR bumping `talosVersion`/`kubernetesVersion` in both
   `talos/talconfig.yaml` and `values.yaml`.
2. The `talos-k8s-compatibility` workflow checks that the new Kubernetes
   version is supported by the new Talos version.
3. After merge, tuppr upgrades the nodes - for each gate that is enabled.

## Gates

| Value | Renders | Enable when |
|-------|---------|-------------|
| `talos.supportsRpi5` | `TalosUpgrade` | `talosctl upgrade` has been run by hand on rpi5 once |
| `kubernetes.upgradeEnabled` | `KubernetesUpgrade` | Together with `talos.supportsRpi5` |

The two gates move together because Renovate bumps both versions in one PR,
and the compatibility check compares the two *target* versions. With only the
Kubernetes gate on, tuppr would apply the new Kubernetes minor to nodes still
running the old Talos, which may not support it.

## Resources

- [Tuppr GitHub](https://github.com/home-operations/tuppr)
