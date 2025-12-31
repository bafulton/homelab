# Traefik

Kubernetes ingress controller and reverse proxy.

## Access

The Traefik dashboard is exposed via Tailscale at `https://traefik.<tailnet>.ts.net`

## Usage

Traefik handles Ingress resources. For services exposed via Tailscale, use the `tailscale` ingress class instead (see tailscale-operator).

For internal routing or advanced features (middleware, TCP/UDP routing), use Traefik's CRDs:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-route
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`my-service.local`)
      kind: Rule
      services:
        - name: my-service
          port: 80
```
