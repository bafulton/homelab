# ArgoCD

GitOps continuous delivery for Kubernetes. Watches this repo and automatically syncs cluster state.

## Access

`https://argocd.catfish-mountain.com` (requires the Tailscale `group:homelab-admins` grant through
[traefik-admin](../traefik-admin/README.md))

## Credentials

- **Username**: `admin`
- **Password**: Set during cluster bootstrap (stored in `argocd-secret`)

## Persistent OutOfSync Noise

The `argocd` app shows two categories of persistent drift that are cosmetic — neither is a real problem:

### ExternalSecret status drift

ESO updates the `.status` field of ExternalSecrets on every refresh cycle (every minute). ArgoCD detects this as a diff. Suppressed via `ignoreDifferences` on `.status` in `values.yaml`.

### argocd-redis-secret-init (requiresPruning)

Three Helm hook artifacts (ServiceAccount, Role, RoleBinding named `argocd-redis-secret-init`) show `requiresPruning: true` after every ArgoCD self-upgrade. They're pre-upgrade hook resources that Helm would normally delete via `hook-delete-policy: hook-succeeded`, but ArgoCD doesn't enforce Helm's hook delete policy when doing server-side apply.

Pruning is intentionally disabled (`syncPolicy.prune: false`) to prevent ArgoCD from deleting itself if manifest generation fails during a sync. The trade-off is these hook artifacts accumulate. `ignoreDifferences` can't help here — `requiresPruning` means the resource is absent from the desired state entirely, not that its spec differs.

**Options:** manually delete them (they return on next ArgoCD upgrade) or accept the noise.

## Why This Chart Has a Chart.lock

This is the only infra app with a committed `Chart.lock` file. Unlike other apps which are deployed *by* ArgoCD (which handles dependency resolution during sync), this chart is installed directly via Helm during `bootstrap.sh` before ArgoCD exists. The lock file ensures reproducible installs by pinning the exact dependency version.

The first Helm install uses `talos/argocd-bootstrap-values.yaml` to omit the
HTTPRoutes and ExternalSecret until their CRDs exist. After the root Application
is applied, the generated `argocd` Application renders this chart without those
overrides and manages the full configuration. Do not run a later Helm upgrade
with the bootstrap overrides after the root Application exists.
