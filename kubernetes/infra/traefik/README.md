# Traefik

Kubernetes ingress controller and reverse proxy for LAN HTTP routing.

## Access

| Method | Address | Use Case |
|--------|---------|----------|
| Tailscale | `https://traefik.catfish-mountain.ts.net` | Dashboard (remote) |
| LAN | `http://192.168.0.200:8080` | Dashboard (local) |

## How It Works

Traefik receives HTTP traffic on its MetalLB IP (`192.168.0.200`) and routes to services based on hostname rules:

```
Browser → 192.168.0.200 → Traefik → IngressRoute → Service → Pod
              ↑
        /etc/hosts maps
        hostname to IP
```

## MetalLB IP

Traefik is assigned `192.168.0.200` via MetalLB. Check the current IP:

```bash
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## Adding a New LAN Service

### Option 1: Use the traefik-ingress shared chart (recommended)

Add to your app's `Chart.yaml`:

```yaml
dependencies:
  - name: traefik-ingress
    version: 1.0.0
    repository: file://../../../charts/traefik-ingress
```

Configure in `values.yaml`:

```yaml
traefik-ingress:
  ingresses:
    - name: lan
      hostname: myapp.local
      service:
        name: myapp-server
        port: 8080
```

### Option 2: Create IngressRoute manually

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-route
  namespace: my-namespace
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`myapp.local`)
      kind: Rule
      services:
        - name: my-service
          port: 80
```

### Update /etc/hosts

Add the hostname to your local machine's `/etc/hosts`:

```
192.168.0.200    myapp.local
```

## Current Routes

| Hostname | Service | App |
|----------|---------|-----|
| `home.local` | home-assistant:80 | Home Assistant |
| `media.local` | jellyfin:8096 | Jellyfin |

## Entrypoints

| Name | Port | Protocol |
|------|------|----------|
| `web` | 80 | HTTP |
| `websecure` | 443 | HTTPS (unused - Tailscale handles TLS) |
| `traefik` | 8080 | Dashboard API |

## Dashboard

The Traefik dashboard shows all routers, services, and middlewares. Access via:
- **Remote**: `https://traefik.catfish-mountain.ts.net`
- **Local**: `http://192.168.0.200:8080`

The dashboard is exposed without authentication because it's only accessible via Tailscale (which provides authentication) or the local network.
