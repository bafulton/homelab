# Homelab

GitOps-driven Kubernetes cluster for my homelab, running on Talos Linux with Tailscale for secure networking.

## Approach

- **OS**: [Talos Linux](https://www.talos.dev/) - immutable, API-driven Kubernetes OS
- **Networking**: [Tailscale](https://tailscale.com/) - nodes communicate over a private mesh network
- **GitOps**: [ArgoCD](https://argo-cd.readthedocs.io/) - all cluster state is defined in this repo
- **Dependency Updates**: [Renovate](https://docs.renovatebot.com/) - automated PRs for version updates

## Repository Structure

```
homelab/
├── talos/          # Talos Linux bootstrap scripts and configs
│   └── README.md   # Full bootstrap guide (start here!)
└── kubernetes/     # GitOps manifests managed by ArgoCD
    ├── appsets/    # ApplicationSets that generate ArgoCD apps
    ├── infra/      # Infrastructure components (cert-manager, traefik, etc.)
    └── apps/       # User application Helm charts
```

## Automated Updates

[Renovate](https://docs.renovatebot.com/) monitors dependencies and creates PRs when updates are available.

| Update Type | Behavior |
|-------------|----------|
| Helm chart minor/patch | Auto-merged after CI passes |
| Helm chart major | Manual review required |
| Talos/Kubernetes | Manual review required |

### Talos & Kubernetes Upgrades

Talos and Kubernetes versions are grouped together since Kubernetes compatibility depends on the Talos version. When updates are available:

1. Renovate creates a PR updating both `talos/talconfig.yaml` and the upgrade CRs
2. [CI validates](.github/workflows/talos-k8s-compatibility.yaml) the Kubernetes version is compatible with the Talos version
3. After merge, [tuppr](https://github.com/home-operations/tuppr) orchestrates the upgrade safely (node-by-node with health checks)

## Dashboards

- [ArgoCD](https://argocd.catfish-mountain.ts.net) - GitOps deployments
- [Kubernetes Dashboard](https://kube-dashboard.catfish-mountain.ts.net) - Cluster management
- [SigNoz](https://signoz.catfish-mountain.ts.net) - Observability (metrics, logs, traces)
- [Traefik](https://traefik.catfish-mountain.ts.net) - Ingress controller

## Getting Started

See [`talos/README.md`](talos/README.md) for the complete bootstrap guide.
