# External Secrets

Syncs secrets from external providers into Kubernetes Secrets.

## Secret Store

This chart configures a ClusterSecretStore for Bitwarden, allowing any namespace to pull secrets from your Bitwarden vault.

## Usage

Create an ExternalSecret to sync a Bitwarden item:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: bitwarden-secretsmanager
    kind: ClusterSecretStore
  target:
    name: my-secret
  data:
    - secretKey: password
      remoteRef:
        key: <bitwarden-item-id>
        property: password
```
