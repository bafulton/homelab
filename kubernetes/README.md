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

ArgoCD uses [sync-waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) to control deployment order. Infrastructure deploys in negative waves so apps (wave 0+) always start after infrastructure is ready.

```mermaid
flowchart LR
    subgraph wave4["-4: Foundational"]
        cm[cert-manager]
        lh[longhorn]
    end

    subgraph wave3["-3: Secrets"]
        es[external-secrets]
    end

    subgraph wave2["-2: Networking"]
        mlb[metallb]
        ts[tailscale-operator]
    end

    subgraph wave1["-1: Services"]
        argo[argocd]
        kd[kubernetes-dashboard]
        tf[traefik]
        tuppr[tuppr]
        ms[metrics-server]
    end

    subgraph wave0["0+: Apps"]
        apps[apps/*]
    end

    wave4 --> wave3 --> wave2 --> wave1 --> wave0
    cm -.->|webhook certs| es
    cm -.->|webhook certs| tuppr
    lh -.->|PVCs| apps
    es -.->|OAuth secret| ts
    ts -.->|Ingress| argo
    ts -.->|Ingress| kd
    ts -.->|Ingress| tf
```

| Wave | Category | Components | Purpose |
|------|----------|------------|---------|
| -4 | Foundational | cert-manager, longhorn | TLS certificates, persistent storage |
| -3 | Secrets | external-secrets | Pull secrets from Bitwarden |
| -2 | Networking | metallb, tailscale-operator | Load balancing, tailnet exposure |
| -1 | Services | argocd, kubernetes-dashboard, traefik, tuppr, metrics-server | Platform services |
| 0+ | Apps | `apps/*` | User applications |

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
