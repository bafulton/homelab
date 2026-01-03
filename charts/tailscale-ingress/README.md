# tailscale-ingress

A reusable Helm chart for creating Tailscale Ingress resources.

## Features

- Create multiple Ingress resources per app
- Optional Tailscale Funnel support (expose to public internet)
- Path-based routing for Funnel ingresses
- Optional Service creation with custom pod selectors

## Usage

Add as a dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: tailscale-ingress
    version: 1.0.0
    repository: file://../../../charts/tailscale-ingress
    condition: tailscale-ingress.enabled
```

Configure in your `values.yaml`:

```yaml
tailscale-ingress:
  enabled: true
  ingresses:
    # Simple ingress using existing service
    - name: tailscale
      hostname: myapp
      service:
        name: myapp-server

    # Ingress with Funnel (public internet access)
    - name: webhook
      hostname: myapp-webhook
      service:
        name: myapp-server
      funnel:
        enabled: true
        path: /api/webhook

    # Ingress with new service creation
    - name: dashboard
      hostname: myapp-dashboard
      service:
        create: true
        targetPort: 8080
        targetSelector:
          app.kubernetes.io/name: myapp
```

## Values

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable/disable the chart | `false` |
| `ingresses` | List of ingress configurations | `[]` |
| `ingresses[].name` | Suffix for resource names | Required |
| `ingresses[].hostname` | Tailscale hostname | Required |
| `ingresses[].service.name` | Existing service name | - |
| `ingresses[].service.port` | Service port | `80` |
| `ingresses[].service.create` | Create a new service | `false` |
| `ingresses[].service.targetPort` | Pod port (if creating service) | `80` |
| `ingresses[].service.targetSelector` | Pod selector (if creating service) | - |
| `ingresses[].funnel.enabled` | Enable Tailscale Funnel | `false` |
| `ingresses[].funnel.path` | Restrict Funnel to path | - |

## Resources Created

For each entry in `ingresses`:

- **Ingress**: `<release>-<name>` with `ingressClassName: tailscale`
- **Service** (if `service.create: true`): `<release>-<name>`
