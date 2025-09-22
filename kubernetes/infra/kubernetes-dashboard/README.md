# Kubernetes Dashboard

## Long-lived login token

To login to the dashboard, you will need to provide a bearer token. Here's how you can ge tthat value:
```yaml
kubectl get secret kube-dashboard-admin -n kubernetes-dashboard -o jsonpath="{.data.token}" | base64 -d
```
