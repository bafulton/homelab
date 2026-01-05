# ArgoCD

GitOps continuous delivery for Kubernetes. Watches this repo and automatically syncs cluster state.

## Access

Exposed via Tailscale at `https://argocd.<tailnet>.ts.net`

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
  enabled: true
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

## Why This Chart Has a Chart.lock

This is the only infra app with a committed `Chart.lock` file. Unlike other apps which are deployed *by* ArgoCD (which handles dependency resolution during sync), this chart is installed directly via Helm during `bootstrap.sh` before ArgoCD exists. The lock file ensures reproducible installs by pinning the exact dependency version.
