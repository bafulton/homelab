# Tuppr

Automated Talos and Kubernetes upgrade orchestration.

## How It Works

Tuppr watches for `TalosUpgradePlan` and `KubernetesUpgradePlan` CRs and safely upgrades nodes one at a time with health checks between each.

## Usage

Upgrades are managed via Renovate:

1. Renovate creates a PR updating versions in `talconfig.yaml` and upgrade CRs
2. CI validates Kubernetes version is compatible with Talos version
3. After merge, Tuppr executes the upgrade plan

## Manual Upgrades

Create upgrade plan CRs to trigger upgrades:

```yaml
apiVersion: tuppr.io/v1alpha1
kind: TalosUpgradePlan
metadata:
  name: upgrade-to-v1.x.x
spec:
  version: v1.x.x
  # nodes will be upgraded one at a time
```

## Resources

- [Tuppr GitHub](https://github.com/home-operations/tuppr)
