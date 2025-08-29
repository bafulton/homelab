# This script bootstraps ArgoCD into kubernetes and spins up
# the app-of-app(set)s. You should only run it once.

# Create the argocd namespace
kubectl get ns argocd >/dev/null 2>&1 || kubectl create ns argocd

# Apply the ArgoCD Application (installs Argo via Helm values in infra/argocd)
kubectl apply -f kubernetes/bootstrap/app-argocd.yaml

# Wait for Argo controllers to be ready
kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=5m
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=5m
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

# Apply your root app that points at appsets/
kubectl apply -f kubernetes/application.yaml
