# cert-manager

Automated TLS certificate management for Kubernetes.

## Certificate Strategies

This cluster uses **two certificate issuers** depending on the use case:

| Issuer | Use Case | Browser Trusted | Validity |
|--------|----------|-----------------|----------|
| `letsencrypt-production` | **Public/private domains** - Use for `*.catfish-mountain.com` and other domains accessible via Tailscale | ✅ Yes | 90 days (auto-renews) |
| `homelab-ca` | **Internal cluster services** - Use for `.svc.cluster.local` and pod-to-pod communication | ❌ No (self-signed) | 1 year (10yr root CA) |

## Certificate Hierarchies

### Let's Encrypt (Public CA)

```
Let's Encrypt ACME Server
    └── letsencrypt-production (ClusterIssuer)
            └── Your certificates (e.g., *.catfish-mountain.com)
```

**Configuration:**
- Uses Cloudflare DNS-01 challenge for domain validation
- API token stored in `cloudflare-api-token` secret (synced from Bitwarden)
- Auto-renews 30 days before 90-day expiration
- Browser-trusted certificates (no warnings)

### Homelab CA (Internal PKI)

```
selfsigned-bootstrap (ClusterIssuer)
    └── homelab-root-ca (Certificate, 10yr, RSA-4096)
            └── homelab-ca (ClusterIssuer)
                    └── Your certificates (e.g., bitwarden-sdk-server.svc.cluster.local)
```

## Cluster Issuers

| Issuer | Use Case |
|--------|----------|
| `letsencrypt-production` | **Use for external-facing services** - Services accessed via browser or Tailscale that need trusted certificates |
| `homelab-ca` | **Use for internal services** - Cluster-internal communication (webhooks, service mesh, etc.) |
| `selfsigned-bootstrap` | **Internal only** - Creates the homelab root CA. Do not use directly. |

## Usage

### Public/Private Domains (Let's Encrypt)

Use for services accessed via browser or Tailscale:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-catfish-mountain-com
spec:
  secretName: wildcard-catfish-mountain-com-tls
  duration: 2160h  # 90 days
  renewBefore: 720h  # 30 days before expiration
  dnsNames:
    - "catfish-mountain.com"
    - "*.catfish-mountain.com"
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
```

### Internal Cluster Services (Homelab CA)

Use for pod-to-pod communication and internal webhooks:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-internal-service
spec:
  secretName: my-internal-service-tls
  duration: 8760h  # 1 year
  renewBefore: 720h  # 30 days
  dnsNames:
    - my-service
    - my-service.my-namespace
    - my-service.my-namespace.svc
    - my-service.my-namespace.svc.cluster.local
  issuerRef:
    name: homelab-ca
    kind: ClusterIssuer
```

## Notes

- **Public domains** (*.fultonhuffman.com, etc.) use **Cloudflare Universal SSL** - no Kubernetes certificates needed
- **Private domain** (*.catfish-mountain.com) uses **Let's Encrypt** - accessible only via Tailscale Split DNS
- All Let's Encrypt certificates require the `cloudflare-api-token` secret (managed by bitwarden-secret chart)
