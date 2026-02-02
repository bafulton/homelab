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

## Sync Waves

ArgoCD uses [sync-waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) to control deployment order.

**Philosophy**: Avoid sync waves unless strictly necessary. Most apps should use the default (wave 0) and rely on ArgoCD's automatic retry for dependency resolution.

### Critical Dependency Chain

There is one critical dependency chain that requires explicit sync waves:

```
cert-manager (-2) → external-secrets (-1) → tailscale-operator (0)
```

- **cert-manager → external-secrets**: External Secrets webhook needs TLS certs from cert-manager
- **external-secrets → tailscale-operator**: Tailscale operator needs the `operator-oauth` secret from Bitwarden

Everything else uses the default (wave 0) and self-heals via ArgoCD retry.

### Setting Sync Waves

Apps can set their sync wave in `values.yaml`:

```yaml
syncWave: "-1"  # Deploy in wave -1 (before wave 0)
```

The ApplicationSet reads this field and converts it to the `argocd.argoproj.io/sync-wave` annotation.

**Note**: Both `infra/` and `apps/` ApplicationSets sync simultaneously. There is no ordering between infrastructure and user applications at the ApplicationSet level.

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
