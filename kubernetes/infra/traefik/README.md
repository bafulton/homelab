# Traefik

Kubernetes Gateway API implementation that routes all HTTP traffic in the cluster.

## Access

| Method | Address | Use Case |
|--------|---------|----------|
| Private (Tailscale) | `https://traefik.catfish-mountain.com` | Dashboard (remote) |
| LAN | `http://192.168.0.200:8080` | Dashboard (local) |

## Architecture

Traefik implements the **Gateway API** standard and serves as the single HTTP entry point for the cluster:

```
Traffic Sources:
├── Cloudflare Tunnel (public: *.fultonhuffman.com, etc.)
├── Tailscale Split DNS (private: *.catfish-mountain.com)
└── LAN/mDNS (*.local)
         ↓
    192.168.0.200 (MetalLB)
         ↓
   Traefik Gateway
         ↓
   HTTPRoute resources (Gateway API)
         ↓
   Services → Pods
```

All three traffic sources (public, private, LAN) route through the same Traefik Gateway at `192.168.0.200`.

## Gateway Resource

This deployment creates a single `Gateway` resource in the `traefik` namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: traefik
  namespace: traefik
spec:
  gatewayClassName: traefik
  listeners:
    - name: web
      port: 80
      protocol: HTTP
```

**Note:** The Gateway allows HTTPRoutes from **all namespaces** via `namespacePolicy.from: All`. Apps create HTTPRoutes in their own namespace using the `gateway-route` shared chart.

## Adding a New Service

**Use the gateway-route shared chart** (see `charts/gateway-route/README.md`):

Add to your app's `Chart.yaml`:

```yaml
dependencies:
  - name: gateway-route
    version: 1.0.0
    repository: file://../../../charts/gateway-route
```

Configure in `values.yaml`:

```yaml
gateway-route:
  routes:
    - name: myapp
      hostnames:
        - myapp.fultonhuffman.com      # Public
        - myapp.catfish-mountain.com   # Private
        - myapp.local                  # LAN
      service:
        name: myapp-server
        port: 8080
```

This creates an HTTPRoute that references the `traefik` Gateway. One route can handle multiple hostnames for different access methods.

## MetalLB IP

Traefik is assigned `192.168.0.200` via MetalLB. Check the current IP:

```bash
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## TLS/HTTPS

- **Cloudflare Tunnel**: TLS terminated by Cloudflare (Cloudflare Universal SSL)
- **Tailscale Split DNS**: TLS provided by Let's Encrypt wildcard cert (`*.catfish-mountain.com`)
- **LAN (*.local)**: HTTP only (no TLS)

The Gateway itself operates on port 80 (HTTP). TLS termination happens at different layers depending on the traffic source.

## Dashboard

The Traefik dashboard shows Gateway status, HTTPRoutes, and backend services:
- **Private**: `https://traefik.catfish-mountain.com`
- **LAN**: `http://192.168.0.200:8080`

The dashboard is exposed without authentication because access is controlled by Tailscale (for private) or physical network (for LAN).

## Listing Routes

View all HTTPRoutes in the cluster:

```bash
kubectl get httproute -A
```

View details for a specific route:

```bash
kubectl describe httproute -n my-namespace my-route
```
