# gateway-route

Shared Helm chart for creating HTTPRoute resources for Gateway API routing. Supports unified routing for both public access (via Cloudflare Tunnel) and LAN access (via MetalLB) through a single HTTPRoute.

## Overview

This chart replaces the deprecated `traefik-ingress` chart and uses Kubernetes Gateway API instead of Traefik-specific IngressRoute CRDs. The Gateway API provides:
- Vendor-neutral, standardized routing
- Single HTTPRoute for both public (Cloudflare Tunnel) and LAN (MetalLB) traffic
- Better multi-tenant support with explicit Gateway references

## Migration from traefik-ingress

Replace in your `Chart.yaml`:
```yaml
# Old
- name: traefik-ingress
  version: 1.0.0
  repository: file://../../../charts/traefik-ingress

# New
- name: gateway-route
  version: 1.0.0
  repository: file://../../../charts/gateway-route
```

Update your `values.yaml`:
```yaml
# Old traefik-ingress format
traefik-ingress:
  ingresses:
    - name: lan
      hostname: myapp.local
      service:
        name: myapp-service
        port: 80

# New gateway-route format
gateway-route:
  routes:
    - name: lan
      hostnames:              # Note: array instead of single hostname
        - myapp.fultonhuffman.com  # Public via Cloudflare Tunnel
        - myapp.local              # LAN via mDNS
      service:
        name: myapp-service
        port: 80
```

## Usage

Add as a dependency in your app's `Chart.yaml`:

```yaml
dependencies:
  - name: gateway-route
    version: 1.0.0
    repository: file://../../../charts/gateway-route
```

Configure routes in your `values.yaml`:

```yaml
gateway-route:
  routes:
    - name: myapp
      hostnames:
        - myapp.catfish-mountain.com
      service:
        name: myapp-service
        port: 80
```

## Configuration

### Gateway Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `gateway.name` | Name of the Gateway resource | `traefik` |
| `gateway.namespace` | Namespace of the Gateway | `traefik` |

### Route Configuration

Each route supports the following parameters:

| Parameter | Description | Required |
|-----------|-------------|----------|
| `name` | Name suffix for the HTTPRoute | Yes |
| `hostnames` | List of hostnames for this route | Yes |
| `service.name` | Name of the backend Service | Yes |
| `service.port` | Port number of the Service | No (default: 80) |
| `rules` | Custom HTTPRoute rules (overrides default catch-all) | No |

## Important Notes

- **Same namespace requirement**: The HTTPRoute and backend Service must be in the same namespace (the release namespace). Cross-namespace routing requires manual ReferenceGrant creation, which is outside the scope of this chart.
- **Gateway access**: The Gateway (in the `traefik` namespace) can route to HTTPRoutes in any namespace because the Gateway is configured with `namespacePolicy.from: All`.

## mDNS Support

Routes can optionally advertise services via mDNS (Bonjour/Zeroconf) for LAN service discovery. This is useful when you have `.local` hostnames for LAN access.

The mDNS configuration creates a ConfigMap with the label `mdns.homelab.io/advertise: "true"` that is picked up by the mdns-advertiser service.

Example with mDNS:

```yaml
gateway-route:
  routes:
    - name: media
      hostnames:
        - media.local                  # LAN access (add to /etc/hosts)
        - media.catfish-mountain.com   # Remote access (DNS)
      service:
        name: jellyfin
        port: 8096
      mdns:
        name: Media Server
        ip: 192.168.0.200              # Gateway MetalLB IP
        port: 8096
        types:
          - type: _http._tcp
```

This allows devices on the LAN to discover the service as `media.local` via Bonjour.

## Example

Full example for an app with multiple routes:

```yaml
gateway-route:
  routes:
    - name: web
      hostnames:
        - myapp.catfish-mountain.com
        - www.myapp.catfish-mountain.com
      service:
        name: myapp-web
        port: 8080

    - name: api
      hostnames:
        - api.myapp.catfish-mountain.com
      service:
        name: myapp-api
        port: 3000
```
