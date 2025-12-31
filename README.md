# Homelab

GitOps-driven Kubernetes cluster for my homelab, running on Talos Linux with Tailscale for secure networking.

## Approach

- **OS**: [Talos Linux](https://www.talos.dev/) - immutable, API-driven Kubernetes OS
- **Networking**: [Tailscale](https://tailscale.com/) - nodes communicate over a private mesh network
- **GitOps**: [ArgoCD](https://argo-cd.readthedocs.io/) - all cluster state is defined in this repo

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

## Getting Started

See [`talos/README.md`](talos/README.md) for the complete bootstrap guide.
