# traefik-ingress

A reusable Helm chart for creating Traefik IngressRoutes for LAN access. Services are exposed via Traefik's MetalLB IP with hostname-based routing.

Access pattern: `http://<hostname>` (add to `/etc/hosts` pointing to Traefik's MetalLB IP)

## Features

- Create multiple IngressRoutes from a single chart
- Hostname-based routing
- Optional middleware support (rate limiting, auth, etc.)
- Configurable entrypoints

## Usage

Add as a dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: traefik-ingress
    version: 1.0.0
    repository: file://../../../charts/traefik-ingress
```

Configure in your `values.yaml`:

```yaml
traefik-ingress:
  ingresses:
    - name: lan
      hostname: myapp.local
      service:
        name: myapp-server
        port: 8080
    - name: api
      hostname: api.local
      service:
        name: myapp-api
        port: 3000
```

## Values

| Key | Description | Default |
|-----|-------------|---------|
| `ingresses` | List of IngressRoute configurations | `[]` |
| `ingresses[].name` | Suffix for resource name | Required |
| `ingresses[].hostname` | Hostname for Host() match rule | Required |
| `ingresses[].service.name` | Service name to route traffic to | Required |
| `ingresses[].service.port` | Service port | `80` |
| `ingresses[].entryPoint` | Traefik entrypoint | `web` |
| `ingresses[].middlewares` | List of middleware references | `[]` |

### Middleware Example

```yaml
traefik-ingress:
  ingresses:
    - name: lan
      hostname: myapp.local
      service:
        name: myapp-server
      middlewares:
        - name: my-ratelimit
          namespace: traefik
```

## Resources Created

- **IngressRoute**: `<release>-<name>` routing `Host(<hostname>)` to the specified service

Empty `ingresses` array = no resources created (effectively disabled).
