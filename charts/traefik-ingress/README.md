# traefik-ingress

A reusable Helm chart for creating Traefik IngressRoutes for LAN, Tailscale (VPN), and public internet access. Services are exposed via Traefik with hostname-based routing.

**Access patterns:**
- **LAN**: `http://<hostname>.local` (auto-discovered via mDNS)
- **Tailscale**: `https://<hostname>.catfish-mountain.ts.net` (via Tailscale proxy)
- **Public**: `https://<hostname>.catfish-mountain.com` (via Cloudflare Tunnel)

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

**Example: LAN access only**
```yaml
traefik-ingress:
  ingresses:
    - name: lan
      host: myapp.local
      service:
        name: myapp-server
        port: 8080
```

**Example: All three traffic sources**
```yaml
traefik-ingress:
  ingresses:
    - name: lan
      host: myapp.local
      service:
        name: myapp-server
        port: 8080
    - name: tailscale
      host: myapp.catfish-mountain.ts.net
      service:
        name: myapp-server
        port: 8080
    - name: public
      host: myapp.catfish-mountain.com
      service:
        name: myapp-server
        port: 8080
```

## Values

| Key | Description | Default |
|-----|-------------|---------|
| `ingresses` | List of IngressRoute configurations | `[]` |
| `ingresses[].name` | Suffix for resource name | Required |
| `ingresses[].host` | Full hostname/FQDN for Host() match rule | Required |
| `ingresses[].service.name` | Service name to route traffic to | Required |
| `ingresses[].service.port` | Service port | `80` |
| `ingresses[].entryPoint` | Traefik entrypoint | `web` |
| `ingresses[].middlewares` | List of middleware references | `[]` |

### Middleware Example

```yaml
traefik-ingress:
  ingresses:
    - name: lan
      host: myapp.local
      service:
        name: myapp-server
      middlewares:
        - name: my-ratelimit
          namespace: traefik
```

## Resources Created

- **IngressRoute**: `<release>-<name>` routing `Host(<hostname>)` to the specified service

Empty `ingresses` array = no resources created (effectively disabled).
