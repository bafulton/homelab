# cert-manager

Automated TLS certificate management for Kubernetes.

## Certificate Hierarchy

```
selfsigned-bootstrap (ClusterIssuer)
    └── homelab-root-ca (Certificate, 10yr, RSA-4096)
            └── homelab-ca (ClusterIssuer)
                    └── Your certificates
```

## Cluster Issuers

| Issuer | Use Case |
|--------|----------|
| `selfsigned-bootstrap` | **Internal only** - Creates the root CA. Do not use directly. |
| `homelab-ca` | **Use this one** - Signs certificates for your services. |

## Usage

Reference `homelab-ca` in your Certificate resources:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-cert
spec:
  secretName: my-cert-tls
  issuerRef:
    name: homelab-ca
    kind: ClusterIssuer
  dnsNames:
    - my-service.example.com
```
