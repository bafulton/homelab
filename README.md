# Homelab

GitOps-driven Kubernetes cluster for my homelab, running on Talos Linux with Tailscale for secure networking.

## Architecture

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
    ├── apps/       # User application Helm charts
    └── infra/      # Infrastructure components (cert-manager, traefik, etc.)
```

## Getting Started

See [`talos/README.md`](talos/README.md) for the complete bootstrap guide.

## Infrastructure Components

| Component | Purpose |
|-----------|---------|
| ArgoCD | GitOps continuous delivery |
| Tailscale Operator | Exposes services via Tailscale |
| cert-manager | TLS certificate management |
| Traefik | Ingress controller |
| MetalLB | Load balancer for bare metal |
| External Secrets | Secrets management (Bitwarden) |
| Kubernetes Dashboard | Cluster web UI |
| Metrics Server | Resource metrics for HPA/VPA |
