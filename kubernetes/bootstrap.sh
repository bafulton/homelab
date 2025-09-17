#!/usr/bin/env bash

# This script installs Helm, bootstraps Argo CD into Kubernetes via
# your internal wrapper chart, and then spins up the app-of-appsets.
# Intended to be run once (typically by DietPi post-install).

set -euo pipefail

# ensure Helm can find the kubeconfig (per https://docs.k3s.io/cluster-access)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log()  { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[warn] %s\n" "$*"; }
err()  { printf "\n[err]  %s\n" "$*" >&2; exit 1; }

if ! command -v helm >/dev/null 2>&1; then
  log "Installing Helm"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/get_helm.sh" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod +x "$tmp/get_helm.sh"
  "$tmp/get_helm.sh"
fi
log "Helm version: $(helm version --short 2>/dev/null || echo 'unknown')"

log "Ensuring Helm dependency repo(s) are configured"
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

log "Making sure 'argocd' namespace exists"
kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd

log "Building Helm dependencies for Argo CD"
helm dependency update infra/argocd

log "Installing Argo CD with Helm"
helm install argocd infra/argocd -n argocd

log "Waiting for core Argo CD deployments to be ready"
wait_dep () {
  local name="$1"
  if kubectl -n argocd get deploy "$name" >/dev/null 2>&1; then
    kubectl -n argocd rollout status deploy/"$name" --timeout=5m
  else
    warn "Deployment '$name' not found (skipping wait)"
  fi
}
wait_dep argocd-application-controller
wait_dep argocd-repo-server
wait_dep argocd-server
wait_dep argocd-applicationset-controller
wait_dep argocd-notifications-controller
wait_dep argocd-dex-server
wait_dep argocd-redis

log "Applying your root Argo CD Application"
kubectl apply -f applications.yaml

log "✓ Bootstrap complete."
