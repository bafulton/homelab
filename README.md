# Homelab

GitOps-driven Kubernetes cluster for my homelab, running on Talos Linux with Tailscale for secure networking.

## Approach

- **OS**: [Talos Linux](https://www.talos.dev/) - immutable, API-driven Kubernetes OS
- **Networking**: [Tailscale](https://tailscale.com/) - nodes communicate over a private mesh network
- **Access Control**: Tailscale administrator grants and separate administrative/application ingress
- **Routing**: Kubernetes Gateway API with separate Traefik admin and apps gateways
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
| Talos/Kubernetes | Custom regex manager | `talos/cluster.yaml`, tuppr values |
| kubectl | Inline Dockerfile annotation | toolbox image (grouped with Kubernetes) |
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
| Talos | Separate PR for each minor version; manual review required |
| Kubernetes/kubectl | Grouped in a separate PR; manual review required |

### Talos & Kubernetes Upgrades

Talos upgrades land before the Kubernetes and kubectl bump they support:

1. Renovate opens a Talos PR updating `talos/cluster.yaml` and the tuppr Talos version. After review and merge, [tuppr](https://github.com/home-operations/tuppr) rolls Talos through the nodes.
2. Renovate opens a separate Kubernetes PR updating `talos/cluster.yaml`, the tuppr Kubernetes version, and the toolbox image's kubectl version. The image version must be bumped for its build.
3. [CI checks](.github/workflows/talos-k8s-compatibility.yaml) compatibility with the Talos version on `main`; after review and merge, tuppr runs the Kubernetes upgrade.

See the [tuppr upgrade cycle](kubernetes/infra/tuppr/README.md#upgrade-cycle) for rollout details.

## Dashboards

Access through the shared [admin gateway](kubernetes/infra/traefik-admin/README.md) requires membership in the Tailscale administrator group. Household and public routes use the separate [apps gateway](kubernetes/infra/traefik-apps/README.md):

- [ArgoCD](https://argocd.catfish-mountain.com) - GitOps deployments
- [SigNoz](https://signoz.catfish-mountain.com) - Observability (metrics, logs, traces)
- [Traefik apps](https://traefik-apps.catfish-mountain.com) - Household/public gateway dashboard
- [Traefik admin](https://traefik-admin.catfish-mountain.com) - Administrative gateway dashboard
- [Gameplane](https://server-admin.fultonhuffman.com) - Game servers for friends (public, Pocket ID sign-in)

## Getting Started

See [`talos/README.md`](talos/README.md) for the complete bootstrap guide.
