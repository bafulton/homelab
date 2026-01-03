# Tailscale Operator

Exposes Kubernetes services directly on your Tailscale network.

## How It Works

The operator watches for Services or Ingresses with Tailscale annotations and creates Tailscale devices to expose them on your tailnet.

## Usage

Add the Tailscale ingress class to expose a service:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
spec:
  ingressClassName: tailscale
  rules:
    - host: my-service
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

The service will be available at `https://my-service.<tailnet>.ts.net`

## Credentials

OAuth credentials are pulled from Bitwarden Secrets Manager via ExternalSecret. The `operator-oauth` secret in the `tailscale` namespace contains `client_id` and `client_secret`.

To set up, add the Bitwarden secret IDs to `values.yaml`:
```yaml
oauth:
  bitwardenSecretIds:
    clientId: "<bitwarden-secret-uuid>"
    clientSecret: "<bitwarden-secret-uuid>"
```
