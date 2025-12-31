# cert-manager

Automated TLS certificate management for Kubernetes.

## Cluster Issuers

This chart creates a self-signed CA for the homelab:

1. `selfsigned-bootstrap` - Bootstrap issuer for creating the root CA
2. `homelab-ca` - ClusterIssuer that signs certificates using the homelab root CA

## Usage

Reference the issuer in your Ingress or Certificate resources:

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
