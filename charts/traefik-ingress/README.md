# traefik-ingress

A reusable Helm chart for creating Traefik IngressRoutes for LAN access. Services are exposed via Traefik's MetalLB IP with hostname-based routing.

Access pattern: `http://<hostname>` (add to `/etc/hosts` pointing to Traefik's MetalLB IP)

## Features

- Create IngressRoutes with hostname-based routing
- Optional middleware support (rate limiting, auth, etc.)
- Configurable entrypoints

## Usage

Add as a dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: traefik-ingress
    version: 1.0.0
    repository: file://../../../charts/traefik-ingress
    condition: traefik-ingress.enabled
```

Configure in your `values.yaml`:

```yaml
traefik-ingress:
  enabled: true
  hostname: myapp.local
  service:
    name: myapp-server
    port: 8080
```

Then add to your `/etc/hosts`:

```
192.168.0.200    myapp.local
```

## Values

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable/disable the chart | `false` |
| `hostname` | Hostname for the Host() match rule | Required |
| `service.name` | Service name to route traffic to | Required |
| `service.port` | Service port | `80` |
| `entryPoint` | Traefik entrypoint | `web` |
| `middlewares` | List of middleware references | `[]` |

### Middleware Example

```yaml
traefik-ingress:
  enabled: true
  hostname: myapp.local
  service:
    name: myapp-server
  middlewares:
    - name: my-ratelimit
      namespace: traefik
```

## Resources Created

- **IngressRoute**: `<release>-lan` routing `Host(<hostname>)` to the specified service
