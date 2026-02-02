# Claude Context for Homelab

## Git Workflow

Commit directly to main for routine changes. Use PRs for larger changes that benefit from review.

## Project Overview

GitOps-driven Kubernetes homelab running on Talos Linux with Tailscale networking. Tailnet: `catfish-mountain.ts.net`

## GitOps Pattern

Each app in `infra/` or `apps/` is a wrapper Helm chart:
- `Chart.yaml` - Declares upstream chart as dependency
- `values.yaml` - Configuration values (also read by ApplicationSet for metadata)
- `templates/` - Additional resources (e.g., Gateway API routes, Secrets)

The ApplicationSets scan for `values.yaml` files and generate ArgoCD Applications automatically.

### Adding a New App

1. Create directory: `kubernetes/infra/my-app/` or `kubernetes/apps/my-app/`
2. Add `Chart.yaml` with upstream dependency
3. Add `values.yaml` with configuration
4. Commit and push - ArgoCD auto-syncs

### Values.yaml Conventions

```yaml
# Optional: Override namespace (defaults to directory name)
namespace: custom-namespace

# Optional: Enable server-side apply for CRD-heavy charts
serverSideApply: true

# Gateway API routing (for public, LAN, or private access)
gateway-route:
  routes:
    - name: main
      hostnames:
        - my-app.fultonhuffman.com  # Public (via Cloudflare Tunnel)
        - my-app.local              # LAN (via mDNS)
      service:
        name: my-app-server
        port: 80

# Upstream chart values nested under chart name
my-upstream-chart:
  key: value
```

## Important Patterns

### Gateway API Routes (Primary Pattern)

**All services** use the `gateway-route` shared chart with Kubernetes Gateway API HTTPRoutes:

```yaml
# Chart.yaml
dependencies:
  - name: gateway-route
    version: 1.0.0
    repository: file://../../../charts/gateway-route

# values.yaml
gateway-route:
  routes:
    - name: public-lan
      hostnames:
        - myapp.fultonhuffman.com  # Public via Cloudflare Tunnel
        - myapp.local              # LAN via mDNS
      service:
        name: my-app-server
        port: 8080
      mdns:                        # Optional: mDNS advertisement
        name: My App
        ip: 192.168.0.200          # Gateway MetalLB IP
```

**Private infrastructure (catfish-mountain.com):**
```yaml
gateway-route:
  routes:
    - name: private
      hostnames:
        - myapp.catfish-mountain.com  # Tailscale Split DNS only
      service:
        name: my-app-server
        port: 80
```

**Multiple routes for different access patterns:**
```yaml
gateway-route:
  routes:
    - name: ui
      hostnames:
        - myapp.catfish-mountain.com  # Private UI
      service:
        name: myapp-server
        port: 80
    - name: webhook
      hostnames:
        - myapp-webhook.catfish-mountain.com  # Public webhook
      service:
        name: myapp-server
        port: 80
```

### mDNS Advertisement

For LAN service discovery (Bonjour/Zeroconf), use the `mdns-config` shared chart:

```yaml
# Chart.yaml
dependencies:
  - name: mdns-config
    version: 1.0.0
    repository: file://../../../charts/mdns-config

# values.yaml
mdns-config:
  services:
    - name: My App
      hostname: myapp        # becomes myapp.local
      ip: 192.168.0.200      # MetalLB or Traefik IP
      port: 80
      types:
        - type: _http._tcp
```

The central `mdns-advertiser` discovers labeled ConfigMaps and advertises them via mDNS.

### PodSecurity

Kubernetes enforces PodSecurity standards. Most namespaces use "baseline" but some require "privileged":
- `longhorn` - Storage operations require privileged access
- `metallb` - Speaker needs NET_RAW, hostNetwork for L2/ARP

Add namespace template with labels if privileged access needed:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Release.Namespace }}
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

## Domain Strategy

**Domain usage patterns:**
- `*.catfish-mountain.ts.net` → Tailscale network resources (gateway, DNS, physical devices)
- `*.catfish-mountain.com` → Infrastructure (dashboards, webhooks, etc.) - **private by default**
  - Accessible only via Tailscale Split DNS when connected to tailnet
  - Specific public exceptions defined in `terraform/cloudflare/variables.tf` (`public_subdomains`)
- `*.fultonhuffman.com`, `*.yak-shave.com`, `*.benfulton.me` → Public services

**Cloudflare Tunnel routing** is explicitly controlled:
- Wildcard routing for public domains only
- Specific subdomain exceptions for catfish-mountain.com (e.g., argocd-webhook)
- All other catfish-mountain.com requests → 404

## Certificate Management

**Public domains** (*.fultonhuffman.com, *.yak-shave.com, *.benfulton.me):
- Managed by **Cloudflare Universal SSL** (automatic, Cloudflare terminates TLS)
- No configuration needed in Kubernetes

**Private domain** (*.catfish-mountain.com):
- Managed by **Let's Encrypt** via cert-manager
- Configured in: `kubernetes/infra/cert-manager/templates/letsencrypt-cloudflare-issuer.yaml`
- Uses Cloudflare DNS-01 challenge (API token from Bitwarden)
- Auto-renews 30 days before 90-day expiration
- Browser-trusted certificates (no self-signed warnings)

**Internal cluster services** (.svc.cluster.local):
- Managed by **homelab-ca** (internal PKI)
- Self-signed root CA, 10-year validity
- Used for pod-to-pod communication, webhooks

**Certificate hierarchy:**
```
# Public
Let's Encrypt (production) → *.catfish-mountain.com

# Internal
selfsigned-bootstrap → homelab-root-ca → homelab-ca → service certs
```

See `kubernetes/infra/cert-manager/README.md` for details.

## Secrets Management

**Bootstrap secrets** (created during `bootstrap.sh`):
- **ArgoCD admin password** - `argocd-secret` in `argocd` namespace
- **Bitwarden access token** - `bitwarden-access-token` in `external-secrets` namespace

**Bitwarden-managed secrets** (via External Secrets Operator):
- **Tailscale OAuth** - `operator-oauth` in `tailscale` namespace
- **Cloudflare API token** - `cloudflare-api-token` in `cert-manager` namespace (for Let's Encrypt)

**Talos secrets** (gitignored):
- `talsecret.yaml` - Cluster PKI, generated by talhelper
- `.env` - Tailscale auth key for Talos extension

## Gotchas

- **Check upstream chart values first**: Before adding configuration to an app's `values.yaml`, always run `helm show values <repo>/<chart>` to verify the correct parameter names. Different charts use different conventions (e.g., `extraVolumes` vs `additionalVolumes` vs `volumes`). Don't assume parameter names.
- **Metrics-server TLS**: Uses `--kubelet-insecure-tls` because kubelet certs don't include Tailscale IP SANs
- **Chart.lock files**: ArgoCD is the only app with a Chart.lock. All other apps don't need one because ArgoCD runs `helm dependency build` at sync time. Don't suggest adding Chart.lock to apps.
- **Chart tarballs (.tgz)**: The `charts/` subdirectories contain `.tgz` files from `helm dependency build`. These are gitignored - don't suggest cleaning them up or committing them.
- **DaemonSet retry backoff**: After fixing a failing DaemonSet, may need `kubectl rollout restart` to clear backoff
- **Tailscale proxy pods**: Named `ts-<service>-<hash>-0` in the `tailscale` namespace
