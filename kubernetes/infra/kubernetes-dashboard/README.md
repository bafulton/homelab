# Kubernetes Dashboard

Web-based UI for managing and troubleshooting your cluster.

## Access

Exposed via Tailscale at `https://kube-dashboard.<tailnet>.ts.net`

## Authentication

To login, you'll need a bearer token. Get it with:

```bash
kubectl get secret kube-dashboard-admin -n kubernetes-dashboard -o jsonpath="{.data.token}" | base64 -d
```
