# cloudflared

Cloudflare Tunnel for secure public internet ingress without exposing ports or public IPs.

## Overview

Cloudflare Tunnel creates an outbound-only connection from the cluster to Cloudflare's edge network. Public traffic routes through Cloudflare and into the cluster via this tunnel - no port forwarding or firewall configuration needed.

**Architecture:**
```
Public Internet
     ↓
Cloudflare Edge (*.fultonhuffman.com, etc.)
     ↓
Cloudflare Tunnel (secure outbound connection)
     ↓
cloudflared pods in cluster
     ↓
Traefik Gateway (192.168.0.200)
     ↓
HTTPRoute → Service → Pod
```

## Configuration

The tunnel is configured in Cloudflare's dashboard with:
- **Tunnel token**: Stored in Bitwarden, synced as `tunnel-credentials` secret
- **Public hostnames**: Defined in `terraform/cloudflare/variables.tf` (`public_subdomains`)
- **Tunnel route**: Routes to `http://192.168.0.200:80` (Traefik Gateway)

### What's Public?

By default, **all domains are private** (accessible only via Tailscale Split DNS). Only subdomains explicitly listed in `terraform/cloudflare/variables.tf` are routed through the tunnel and publicly accessible:

```hcl
variable "public_subdomains" {
  default = {
    "fultonhuffman.com" = [
      "www",      # www.fultonhuffman.com
      "blog",     # blog.fultonhuffman.com
    ]
  }
}
```

### Private by Default

Services on `*.catfish-mountain.com` are **not** public - they're only accessible when connected to the Tailscale network. This is enforced by:
- Tailscale Split DNS (routes private domains to cluster)
- Cloudflare Tunnel config (only routes configured public subdomains)

## Deployment

This chart deploys:
- **cloudflared Deployment**: 2 replicas for high availability
- **tunnel-credentials Secret**: Tunnel token from Bitwarden (via bitwarden-secret chart)
- **Metrics endpoint**: Prometheus metrics on port 2000

## Tunnel Management

The tunnel itself is created and configured in Cloudflare's dashboard:

1. Navigate to **Zero Trust** → **Networks** → **Tunnels**
2. Find the tunnel (homelab)
3. View/edit public hostname routes
4. Tunnel token is stored in Bitwarden secret ID `d2f5ee49-1c69-4fc3-b286-b3e10043a1d0`

**Note:** Changing public hostnames requires updating both:
- `terraform/cloudflare/variables.tf` (declares DNS records)
- Cloudflare Tunnel routes (in dashboard)

## How Services Become Public

To make a service publicly accessible:

1. Add hostname to `terraform/cloudflare/variables.tf`:
   ```hcl
   variable "public_subdomains" {
     default = {
       "fultonhuffman.com" = ["www", "myapp"]  # Add myapp
     }
   }
   ```

2. Apply Terraform to create DNS record

3. Create HTTPRoute with the public hostname using `gateway-route` chart:
   ```yaml
   gateway-route:
     routes:
       - name: myapp
         hostnames:
           - myapp.fultonhuffman.com  # Public
         service:
           name: myapp-service
           port: 80
   ```

The Cloudflare Tunnel is already configured to route ALL `*.fultonhuffman.com` traffic to the Traefik Gateway. The gateway then routes based on HTTPRoute rules.

## Monitoring

View cloudflared logs:
```bash
kubectl logs -n cloudflared -l app=cloudflared -f
```

Check tunnel status in Cloudflare dashboard:
- **Zero Trust** → **Networks** → **Tunnels** → **homelab**
- Shows connection status, traffic metrics, and routes

## Security

- **Outbound-only connection**: No inbound ports exposed on home network
- **Cloudflare authentication**: Traffic filtered at Cloudflare edge
- **Zero Trust policies**: Can add access policies in Cloudflare dashboard
- **Private by default**: Only explicitly configured subdomains are public
