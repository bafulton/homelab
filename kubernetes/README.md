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

The ApplicationSets put a `sync-wave` annotation on generated Applications,
using `syncWave` from each app's `values.yaml` or `0` by default. The root
Application syncs the ApplicationSet resources; it does not wait for each
generated Application to become healthy before creating the next one. Thus
these annotations do not enforce an inter-Application deployment order.

**Philosophy**: Avoid sync waves unless strictly necessary. Most apps should use the default (wave 0) and rely on ArgoCD's automatic retry for dependency resolution.

No app currently sets `syncWave`, so all generated Applications carry wave 0
and sync independently. cert-manager, external-secrets, and tailscale-operator
have dependencies, but the repository does not enforce that sequence with
ApplicationSet waves. If a dependency is unavailable at first, the affected
Application must recover on a later sync.

### Setting Sync Waves

Apps can set their sync wave in `values.yaml`:

```yaml
syncWave: "-1"  # Deploy in wave -1 (before wave 0)
```

The ApplicationSet reads this field and converts it to the
`argocd.argoproj.io/sync-wave` annotation. The annotation alone does not make
the root Application wait for the generated Application's health.

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
