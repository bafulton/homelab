# MetalLB

Bare-metal load balancer for Kubernetes. Provides LoadBalancer service support without a cloud provider. This makes it so you can make services available locally without needing to use Tailscale.

1. MetalLB assigns external IPs from a configured pool to LoadBalancer services
2. Traefik receives traffic on its assigned IP and routes based on hostname
3. Create Traefik IngressRoutes with, for example, `.lan` hostnames for local services
4. Add the Traefik IP to your `/etc/hosts` to resolve these hostnames

Example `/etc/hosts` entry:
```
<traefik-external-ip>    plex.lan home.lan
```

Check the current Traefik IP with:
```bash
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## Configuration

This chart creates:

- **IPAddressPool** - Range of IPs MetalLB can assign to LoadBalancer services
- **L2Advertisement** - Announces IPs via ARP on the local network

## Usage

Create a Service with `type: LoadBalancer` and MetalLB will assign an IP from the pool:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  ports:
    - port: 80
```
