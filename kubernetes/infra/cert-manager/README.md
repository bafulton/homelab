# cert-manager

Automated TLS certificate management for Kubernetes.

## Certificate Strategies

This cluster uses **two certificate issuers** depending on the use case:

| Issuer | Use Case | Browser Trusted | Validity |
|--------|----------|-----------------|----------|
| `letsencrypt-production` | **Public/private domains** - Use for `*.catfish-mountain.com` and other domains accessible via Tailscale | ✅ Yes | 90 days (auto-renews) |
| `homelab-ca` | **Internal/LAN services** - `.svc.cluster.local` and explicitly enrolled `.local` clients | ❌ No (self-signed) | 1 year (10yr root CA) |

## Certificate Hierarchies

### Let's Encrypt (Public CA)

```
Let's Encrypt ACME Server
    └── letsencrypt-production (ClusterIssuer)
            └── Your certificates (e.g., *.catfish-mountain.com)
```

**Configuration:**
- Uses Cloudflare DNS-01 challenge for domain validation
- API token stored in `cloudflare-api-token` secret (synced from Bitwarden): its own token, Zone → DNS → Edit on `catfish-mountain.com` and `fultonhuffman.com` only. OpenTofu uses a separate, broader token that stays on the workstation (`opentofu/cloudflare/env.sh`)
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

- **Public domains** (*.fultonhuffman.com, etc.) use **Cloudflare Universal SSL** - no Kubernetes certificates needed, because Cloudflare terminates TLS at its edge
- **Except `media.fultonhuffman.com`**, which reaches the cluster through the OCI edge forwarder (`opentofu/oci-forwarder/`). That host passes TLS through without terminating, so this cluster terminates it and holds a real certificate (`media-fultonhuffman-com`). The `letsencrypt-production` solver therefore lists `fultonhuffman.com` alongside `catfish-mountain.com` - a Certificate for a zone the solver does not list matches no solver at all, creates no Challenge, and sits at `Ready=False` with nothing in its conditions explaining why
- **Infrastructure domain** (*.catfish-mountain.com) uses **Let's Encrypt** - tailnet clients use Tailscale Split DNS, and LAN clients with local name resolution can reach the gateway directly
- All Let's Encrypt certificates require the `cloudflare-api-token` secret (managed by bitwarden-secret chart)

## Household LAN certificates

`homelab-ca` also issues the `household-local` certificate in `traefik-apps` for
`games.local`, `home.local`, and `media.local`. Only clients explicitly trusting
the public root CA can validate it. This reuses the existing issuer; it does not
install a new CA service or distribute private keys. See [household access](../../../docs/lan-https-foundation.md)
for Mac enrollment, leaf renewal, root-rotation planning, and rollback. Root
renewal is not automatic client trust distribution.

## Ingress certificates

[traefik-admin](../traefik-admin/README.md) owns its wildcard Certificate/Secret in
namespace `traefik-admin`; [traefik-apps](../traefik-apps/README.md) owns the household-local
private-CA certificate plus the media/games public certificates in namespace `traefik-apps`.
Public certificates use `letsencrypt-production`; household-local uses `homelab-ca`. No cross-namespace
Secret sharing is needed.
