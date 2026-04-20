# ArgoCD

GitOps continuous delivery for Kubernetes. Watches this repo and automatically syncs cluster state.

## Access

`https://argocd.catfish-mountain.com` (requires Tailscale connection)

## Credentials

- **Username**: `admin`
- **Password**: Set during cluster bootstrap (stored in `argocd-secret`)

## ArgoCD Vault Plugin (AVP)

AVP enables secret injection into Helm charts at render time. This is useful when upstream charts require secrets as plain values (not Secret references) in their values.yaml—for example, API keys, CSRF tokens, or credentials that get embedded into ConfigMaps or other non-Secret resources.

Most charts support `existingSecret` patterns where you reference a Kubernetes Secret. For those, use ExternalSecrets directly. AVP is for the cases where that's not an option.

### How It Works

1. ExternalSecret syncs secret from Bitwarden → Kubernetes Secret
2. App sets `useAVP: true` in values.yaml to opt-in
3. AVP's CMP sidecar processes Helm output, replacing placeholders with secret values

### Usage

In your app's values.yaml:
```yaml
useAVP: true

# Configure ExternalSecret to sync from Bitwarden
bitwarden-secret:
  secrets:
    - name: my-app-secrets
      data:
        apiKey: "<bitwarden-secret-id>"

# Use AVP placeholder syntax in chart values
my-upstream-chart:
  secretValue: <path:my-namespace:my-app-secrets#apiKey>
```

Placeholder syntax: `<path:namespace:secret-name#key>`

### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `avp.enabled` | `true` | Enable AVP sidecar |
| `avp.version` | `v1.18.1` | AVP binary version |

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
