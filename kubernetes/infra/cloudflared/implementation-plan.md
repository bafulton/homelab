# Plan: Add Cloudflare Tunnel for Public Internet Access

## Goal
Enable public internet access to services via custom domains (catfish-mountain.com, catfish-mountain.net, yak-shave.com, benfulton.me) using Cloudflare Tunnel with per-app route declarations, managed via Terraform.

## Architecture

```
Internet → Cloudflare Edge → Encrypted Tunnel → cloudflared → Traefik → Services
```

**Why route through Traefik:**
- Apps declare their own routes (consistent with tailscale-ingress pattern)
- cloudflared stays simple (one static route)
- Traefik middleware available if needed (rate limiting, basic auth)
- No TLS needed internally - Cloudflare terminates TLS at edge, tunnel is encrypted

**Infrastructure split:**
- **Terraform:** Cloudflare zones, tunnel, DNS records
- **Kubernetes:** cloudflared deployment (connects to tunnel)

## Prerequisites (Manual Steps)

1. **Create Cloudflare account** (if needed) at https://dash.cloudflare.com
2. **Add domains to Cloudflare** and change nameservers from Route53:
   - catfish-mountain.com, catfish-mountain.net, yak-shave.com, benfulton.me
3. **Create Cloudflare API token** with permissions:
   - Zone:Zone:Read
   - Zone:DNS:Edit
   - Account:Cloudflare Tunnel:Edit
4. **Export API token** before running Terraform:
   ```bash
   export CLOUDFLARE_API_TOKEN="your-token-here"
   ```

## Implementation

### Step 1: Create `terraform/cloudflare/`

**terraform/cloudflare/main.tf**
```hcl
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  # Uses CLOUDFLARE_API_TOKEN environment variable
}

data "cloudflare_accounts" "main" {}

# Tunnel
resource "cloudflare_tunnel" "homelab" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  name       = "homelab"
  secret     = random_id.tunnel_secret.b64_std
}

resource "random_id" "tunnel_secret" {
  byte_length = 32
}

# Output tunnel token for Kubernetes deployment
output "tunnel_token" {
  value     = cloudflare_tunnel.homelab.tunnel_token
  sensitive = true
}

output "tunnel_id" {
  value = cloudflare_tunnel.homelab.id
}
```

**terraform/cloudflare/variables.tf**
```hcl
variable "domains" {
  type = map(string)
  default = {
    "catfish-mountain-com" = "catfish-mountain.com"
    "catfish-mountain-net" = "catfish-mountain.net"
    "yak-shave-com"        = "yak-shave.com"
    "benfulton-me"         = "benfulton.me"
  }
}

# No need for public_hostnames variable - using wildcard DNS
```

**terraform/cloudflare/zones.tf**
```hcl
# Import existing zones (domains must already be added to Cloudflare)
data "cloudflare_zone" "zones" {
  for_each = var.domains
  name     = each.value
}
```

**terraform/cloudflare/dns.tf**
```hcl
# Wildcard DNS records - all subdomains route to tunnel
resource "cloudflare_record" "wildcard" {
  for_each = data.cloudflare_zone.zones

  zone_id = each.value.id
  name    = "*"
  type    = "CNAME"
  value   = "${cloudflare_tunnel.homelab.id}.cfargotunnel.com"
  proxied = true
}

# Root domain records (optional - for benfulton.me without subdomain)
resource "cloudflare_record" "root" {
  for_each = data.cloudflare_zone.zones

  zone_id = each.value.id
  name    = "@"
  type    = "CNAME"
  value   = "${cloudflare_tunnel.homelab.id}.cfargotunnel.com"
  proxied = true
}
```

**terraform/cloudflare/tunnel_config.tf**
```hcl
# Tunnel ingress configuration - all traffic routes to Traefik
resource "cloudflare_tunnel_config" "homelab" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  tunnel_id  = cloudflare_tunnel.homelab.id

  config {
    # Catch-all rule: route everything to Traefik
    ingress_rule {
      service = "http://traefik.traefik.svc.cluster.local:80"
    }
  }
}
```

**terraform/cloudflare/.gitignore**
```
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl
```

**Add to root .gitignore:**
```
terraform/cloudflare/*.tfstate*
terraform/cloudflare/.terraform/
```

### Step 2: Extend `charts/traefik-ingress/` to Support Multiple Ingresses

Update the chart to match the `tailscale-ingress` pattern (multiple ingresses instead of single).

**charts/traefik-ingress/values.yaml** (new structure)
```yaml
ingresses: []
  # - name: lan
  #   hostname: media.local
  #   service:
  #     name: my-service
  #     port: 8080
```

**charts/traefik-ingress/templates/ingressroute.yaml** (updated)
```yaml
{{- range .Values.ingresses }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ $.Release.Name }}-{{ .name }}
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`{{ .hostname }}`)
      kind: Rule
      services:
        - name: {{ .service.name }}
          port: {{ .service.port }}
{{- end }}
```

### Step 3: Create `kubernetes/infra/cloudflared/`

**Chart.yaml**
```yaml
apiVersion: v2
name: cloudflared
description: Cloudflare Tunnel for public internet ingress
type: application
version: 1.0.0
appVersion: "2024.12.0"
dependencies:
  - name: bitwarden-secret
    version: 1.0.0
    repository: file://../../../charts/bitwarden-secret
    condition: bitwarden-secret.enabled
```

**values.yaml**
```yaml
namespace: cloudflared

bitwarden-secret:
  enabled: true
  secrets:
    - name: tunnel-credentials
      data:
        # After terraform apply, run: terraform output -raw tunnel_token
        # Add this to Bitwarden Secrets Manager, note the UUID
        token: "<bitwarden-secret-uuid>"

cloudflared:
  image: cloudflare/cloudflared:2024.12.0
  replicas: 2
```

**templates/namespace.yaml**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Release.Namespace }}
```

**templates/service.yaml** (for metrics scraping)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: cloudflared-metrics
  labels:
    app: cloudflared
spec:
  selector:
    app: cloudflared
  ports:
    - name: metrics
      port: 2000
      targetPort: metrics
```

**templates/deployment.yaml**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
spec:
  replicas: {{ .Values.cloudflared.replicas }}
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: {{ .Values.cloudflared.image }}
          args:
            - tunnel
            - --protocol
            - quic
            - run
            - --token
            - $(TUNNEL_TOKEN)
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: tunnel-credentials
                  key: token
          ports:
            - name: metrics
              containerPort: 2000
          livenessProbe:
            httpGet:
              path: /ready
              port: metrics
            initialDelaySeconds: 10
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 128Mi
```

Note: The tunnel token contains embedded config. Tunnel ingress routes (→ Traefik) are managed by Terraform in `tunnel_config.tf`. Per-service routing is handled by Traefik via IngressRoute resources.

### Step 4: Update Jellyfin to Declare Public Route

**kubernetes/apps/jellyfin/values.yaml** (updated traefik-ingress section)
```yaml
# Access:
#   - LAN: http://media.local (via Traefik)
#   - Remote: https://jellyfin.catfish-mountain.ts.net (via Tailscale)
#   - Public: https://jellyfin.catfish-mountain.com (via Cloudflare Tunnel)

traefik-ingress:
  ingresses:
    - name: lan
      hostname: media.local
      service:
        name: jellyfin
        port: 8096
    - name: public
      hostname: jellyfin.catfish-mountain.com
      service:
        name: jellyfin
        port: 8096
```

## Files to Create/Modify

| File | Action |
|------|--------|
| `terraform/cloudflare/main.tf` | Create - provider, tunnel |
| `terraform/cloudflare/variables.tf` | Create - domains, hostnames |
| `terraform/cloudflare/zones.tf` | Create - zone data sources |
| `terraform/cloudflare/dns.tf` | Create - wildcard CNAME records |
| `terraform/cloudflare/tunnel_config.tf` | Create - tunnel ingress (→ Traefik) |
| `terraform/cloudflare/.gitignore` | Create - ignore state files |
| `.gitignore` | Update - add terraform patterns |
| `charts/traefik-ingress/values.yaml` | Update - new structure |
| `charts/traefik-ingress/templates/ingressroute.yaml` | Update - loop over ingresses |
| `kubernetes/infra/cloudflared/Chart.yaml` | Create |
| `kubernetes/infra/cloudflared/values.yaml` | Create |
| `kubernetes/infra/cloudflared/templates/namespace.yaml` | Create |
| `kubernetes/infra/cloudflared/templates/service.yaml` | Create - metrics |
| `kubernetes/infra/cloudflared/templates/deployment.yaml` | Create |
| `kubernetes/apps/jellyfin/values.yaml` | Update - new ingress structure |
| `kubernetes/apps/home-assistant/values.yaml` | Update - new ingress structure |

## Adding New Public Services

With wildcard DNS, adding a new public service is simple:

1. **Add public ingress to the app's `values.yaml`:**
   ```yaml
   traefik-ingress:
     ingresses:
       - name: public
         hostname: myapp.catfish-mountain.com
         service:
           name: myapp
           port: 8080
   ```
2. **Commit and push** - ArgoCD syncs, Traefik picks up the new IngressRoute
3. **Done!** - No terraform needed (wildcard covers all subdomains)

Terraform only needed when adding a **new domain** (not subdomain).

## Workflow Summary

```
Initial setup:    terraform apply  → Creates tunnel + wildcard DNS
Adding services:  git push         → ArgoCD deploys IngressRoute
Traffic flows:    Cloudflare → cloudflared → Traefik → Service
```

## Future Enhancements (Not in Scope)

- **SSO/Auth layer:** Add Cloudflare Access or Authentik for unified auth
- **Traefik middleware:** Rate limiting, basic auth for specific routes
- **Cloudflare API token in Bitwarden/BSM:** Store token securely, fetch via CLI before terraform runs
- **Terraform remote state:** S3 backend or Terraform Cloud for team/automation use
