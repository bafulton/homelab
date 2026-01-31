# traefik-ingress

A reusable Helm chart for creating Traefik IngressRoutes for LAN access. Services are exposed via Traefik's MetalLB IP with hostname-based routing.

Access pattern: `http://<hostname>` (add to `/etc/hosts` pointing to Traefik's MetalLB IP)

## Features

- Create multiple IngressRoutes from a single chart
- Hostname-based routing
- Optional middleware support (rate limiting, auth, etc.)
- Configurable entrypoints
- Optional mDNS service advertisement for LAN discovery

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
| `ingresses[].mdns.enabled` | Enable mDNS advertisement | `false` |
| `ingresses[].mdns.name` | Display name for mDNS service | Required if enabled |
| `ingresses[].mdns.ip` | IP address to advertise | Required if enabled |
| `ingresses[].mdns.port` | Port number | `80` |
| `ingresses[].mdns.types` | List of service type objects | Required if enabled |

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

### mDNS Example

Enable mDNS service advertisement for LAN discovery (requires `mdns-advertiser` deployed):

```yaml
traefik-ingress:
  ingresses:
    - name: lan
      hostname: myapp.local
      service:
        name: myapp-server
        port: 8080
      mdns:
        enabled: true
        name: My Application
        ip: 192.168.0.200  # Traefik's MetalLB IP
        port: 80           # External port (HTTP default)
        types:
          - type: _http._tcp
```

The hostname (e.g., `myapp` from `myapp.local`) will be advertised as `myapp.local` on the LAN.

## Resources Created

- **IngressRoute**: `<release>-<name>` routing `Host(<hostname>)` to the specified service
- **ConfigMap** (optional): `<release>-mdns-<hostname>` for mDNS advertisement (when `mdns.enabled: true`)

Empty `ingresses` array = no resources created (effectively disabled).
