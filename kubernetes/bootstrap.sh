#!/usr/bin/env bash

# This script bootstraps Argo CD into kubernetes via Helm using
# the internal wrapper chart and then spins up the app-of-appsets.
# You should only run it once.

set -euo pipefail

echo "==> Ensuring Helm dependency repo(s) are configured"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> Making sure namespace 'argocd' exists"
kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd

echo "==> Building Helm dependencies for argocd"
helm dependency update infra/argocd

echo "==> Installing ArgoCD with Helm"
helm install argocd infra/argocd -n argocd -f infra/argocd/values.yaml

echo "==> Waiting for core ArgoCD deployments to be ready"
wait_dep () {
  local name="$1"
  if kubectl -n argocd get deploy "$name" >/dev/null 2>&1; then
    kubectl -n argocd rollout status deploy/$name --timeout=5m
  fi
}
wait_dep argocd-application-controller
wait_dep argocd-repo-server
wait_dep argocd-server
wait_dep argocd-applicationset-controller
wait_dep argocd-notifications-controller
wait_dep argocd-dex-server
wait_dep argocd-redis

echo "==> Applying your root Argo CD Application"
kubectl apply -f bootstrap.yaml

echo "✓ Bootstrap complete."

echo "==> ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
