# Kubernetes GitOps

This directory contains all Kubernetes manifests managed by ArgoCD.

## Structure

```
kubernetes/
├── applications.yaml   # Root app-of-apps (applied during bootstrap)
├── appsets/            # ApplicationSets that generate ArgoCD Applications
│   ├── infra.yaml      # Generates apps for each chart in infra/
│   └── apps.yaml       # Generates apps for each chart in apps/
├── infra/              # Infrastructure Helm charts
└── apps/               # User application Helm charts
```

## How It Works

1. During bootstrap, `applications.yaml` is applied - this creates a root ArgoCD Application
2. The root app watches `appsets/` and applies the ApplicationSets
3. Each ApplicationSet scans its target directory (`infra/` or `apps/`) and generates an ArgoCD Application for each Helm chart found
4. ArgoCD syncs each Application, deploying the Helm charts to the cluster

## Sync Wave Order

ArgoCD uses [sync-waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) to control the order Applications sync. Infrastructure uses negative waves so user apps (wave 0+) always sync after infrastructure is ready.

```mermaid
flowchart LR
    subgraph wave3[Wave -3: Foundational]
        cm[cert-manager]
        mlb[metallb]
        ms[metrics-server]
    end

    subgraph wave2[Wave -2: Core Services]
        es[external-secrets]
        ts[tailscale-operator]
    end

    subgraph wave1[Wave -1: Platform]
        argo[argocd]
        kd[kubernetes-dashboard]
        tf[traefik]
    end

    subgraph wave0[Wave 0+: User Apps]
        apps[apps/*]
    end

    wave3 --> wave2 --> wave1 --> wave0
    cm -.->|TLS cert| es
    es -.->|webhook secret| argo
    ts -.->|Ingress| argo
    ts -.->|Ingress| kd
    ts -.->|Ingress| tf
```

| Wave | Components | Purpose |
|------|------------|---------|
| -3 | cert-manager, metallb, metrics-server | Foundational - no dependencies |
| -2 | external-secrets, tailscale-operator | Depend on wave -3 components |
| -1 | argocd, kubernetes-dashboard, traefik | Depend on wave -2 components |
| 0+ | User apps in `apps/` | Depend on all infrastructure |

To set a custom sync wave, add `syncWave: "<number>"` to the app's `values.yaml`.

## Adding a New Application

1. Create a new directory under `apps/` with a Helm chart:
   ```
   apps/
   └── my-app/
       ├── Chart.yaml
       ├── values.yaml
       └── templates/
   ```
2. Commit and push - ArgoCD will automatically detect and deploy it
