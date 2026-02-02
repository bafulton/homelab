# Homelab

GitOps-driven Kubernetes cluster for my homelab, running on Talos Linux with Tailscale for secure networking.

## Approach

- **OS**: [Talos Linux](https://www.talos.dev/) - immutable, API-driven Kubernetes OS
- **Networking**: [Tailscale](https://tailscale.com/) - nodes communicate over a private mesh network
- **Access Control**: Tailscale Split DNS + Cloudflare Tunnel for private/public routing
- **Routing**: Kubernetes Gateway API with Traefik gateway
- **GitOps**: [ArgoCD](https://argo-cd.readthedocs.io/) - all cluster state is defined in this repo
- **Dependency Updates**: [Renovate](https://docs.renovatebot.com/) - automated PRs for version updates

## Repository Structure

```
homelab/
├── talos/          # Talos Linux configuration (start here!)
├── kubernetes/     # GitOps manifests managed by ArgoCD
│   ├── appsets/    # ApplicationSets that generate ArgoCD apps
│   ├── infra/      # Infrastructure components (cert-manager, traefik, etc.)
│   └── apps/       # User application Helm charts
├── charts/         # Reusable Helm library charts
└── tailscale/      # Tailscale ACL and GitOps config
```

## Automated Updates

[Renovate](https://docs.renovatebot.com/) monitors dependencies and creates PRs when updates are available.

### What's Tracked

| Dependency Type | Detection Method | Examples |
|-----------------|------------------|----------|
| Helm charts | Built-in manager | `Chart.yaml` dependencies |
| GitHub Actions | Built-in manager | `actions/checkout@v6` |
| Container images | Inline annotations | airconnect, matter-server, python |
| Talos/Kubernetes | Custom regex manager | `talconfig.yaml`, tuppr values |
| kubectl | Custom regex manager | cluster-maintenance (grouped with K8s) |
| argocd-diff-preview | Custom regex manager | Docker image in CI workflow |

Container images in `values.yaml` files use inline annotations:
```yaml
image:
  repository: example/image
  # renovate: datasource=docker depName=example/image
  tag: "1.2.3"
```

### Update Behavior

| Update Type | Behavior |
|-------------|----------|
| Minor/patch updates | Auto-merged after CI passes |
| Major updates | Manual review required |
| Talos/Kubernetes/kubectl | Grouped together, manual review required |

### Talos & Kubernetes Upgrades

Talos, Kubernetes, and kubectl versions are grouped together since compatibility depends on the Talos version. When updates are available:

1. Renovate creates a single PR updating `talos/talconfig.yaml`, tuppr upgrade CRs, and kubectl image
2. [CI validates](.github/workflows/talos-k8s-compatibility.yaml) the Kubernetes version is compatible with the Talos version
3. After merge, [tuppr](https://github.com/home-operations/tuppr) orchestrates the upgrade safely (node-by-node with health checks)

## Dashboards

Access via Tailscale (private by default):

- [ArgoCD](https://argocd.catfish-mountain.com) - GitOps deployments
- [SigNoz](https://signoz.catfish-mountain.com) - Observability (metrics, logs, traces)
- [Traefik](https://traefik.catfish-mountain.com) - Gateway dashboard

## Getting Started

See [`talos/README.md`](talos/README.md) for the complete bootstrap guide.
