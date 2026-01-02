# ArgoCD

GitOps continuous delivery for Kubernetes. Watches this repo and automatically syncs cluster state.

## Access

Exposed via Tailscale at `https://argocd.<tailnet>.ts.net`

## Credentials

- **Username**: `admin`
- **Password**: Set during cluster bootstrap (stored in `argocd-secret`)

## Why This Chart Has a Chart.lock

This is the only infra app with a committed `Chart.lock` file. Unlike other apps which are deployed *by* ArgoCD (which handles dependency resolution during sync), this chart is installed directly via Helm during `bootstrap.sh` before ArgoCD exists. The lock file ensures reproducible installs by pinning the exact dependency version.
