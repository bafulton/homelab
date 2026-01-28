# bitwarden-secret

A reusable Helm chart for creating ExternalSecret resources that pull from Bitwarden Secrets Manager.

## Features

- Create multiple ExternalSecrets per app
- Global defaults with per-secret overrides
- Support for Merge or Owner creation policies
- Custom annotations/labels on ExternalSecret and target Secret

## Usage

Add as a dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: bitwarden-secret
    version: 1.0.0
    repository: file://../../../charts/bitwarden-secret
```

Configure in your `values.yaml`:

```yaml
bitwarden-secret:
  secrets:
    # Simple secret with multiple keys
    - name: operator-oauth
      data:
        client_id: "bitwarden-uuid-1"
        client_secret: "bitwarden-uuid-2"

    # Merge into existing secret
    - name: argocd-secret
      creationPolicy: Merge
      data:
        webhook.github.secret: "bitwarden-uuid-3"

    # With annotations (e.g., for ArgoCD sync-wave)
    - name: early-secret
      annotations:
        argocd.argoproj.io/sync-wave: "-1"
      data:
        api-key: "bitwarden-uuid-4"

    # Custom target secret name and labels
    - name: my-external-secret
      target:
        name: actual-secret-name
        labels:
          app: my-app
      data:
        password: "bitwarden-uuid-5"
```

## Values

| Key | Description | Default |
|-----|-------------|---------|
| `defaults.refreshInterval` | Global refresh interval | `1m` |
| `defaults.creationPolicy` | Global creation policy | `Owner` |
| `secrets` | List of ExternalSecret configurations | `[]` |
| `secrets[].name` | ExternalSecret name (and default target name) | Required |
| `secrets[].refreshInterval` | Override refresh interval | - |
| `secrets[].creationPolicy` | `Owner` or `Merge` | - |
| `secrets[].annotations` | Annotations on ExternalSecret | - |
| `secrets[].labels` | Labels on ExternalSecret | - |
| `secrets[].target.name` | Override target Secret name | - |
| `secrets[].target.annotations` | Annotations on generated Secret | - |
| `secrets[].target.labels` | Labels on generated Secret | - |
| `secrets[].data` | Map of secretKey to Bitwarden secret ID | Required |

## Resources Created

For each entry in `secrets`:

- **ExternalSecret**: `<name>` referencing ClusterSecretStore `bitwarden-secretsmanager`
- **Secret** (managed by ESO): `<name>` or `<target.name>` if specified
