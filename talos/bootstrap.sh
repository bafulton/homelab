#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Talos Cluster Bootstrap Script
# ============================================================================
#
# Bootstraps GitOps infrastructure on a fresh Talos Kubernetes cluster.
# Run this after the cluster is up and you have kubeconfig access.
#
# This script:
#   1. Prompts for required secrets (ArgoCD password, Tailscale OAuth)
#   2. Creates pre-bootstrap Kubernetes secrets
#   3. Installs ArgoCD via Helm
#   4. Applies the root GitOps application
#   5. Verifies the deployment
#
# Usage: ./bootstrap.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"

log()  { printf "\n==> %s\n" "$*"; }
warn() { printf "[warn] %s\n" "$*"; }
err()  { printf "\n[error] %s\n" "$*" >&2; exit 1; }

check_dependencies() {
  log "Checking dependencies"

  if ! command -v kubectl >/dev/null 2>&1; then
    err "kubectl is required but not installed. See: https://kubernetes.io/docs/tasks/tools/"
  fi

  # Verify cluster access
  if ! kubectl cluster-info >/dev/null 2>&1; then
    err "Cannot connect to Kubernetes cluster. Make sure your kubeconfig is set up correctly."
  fi

  # Install Helm if missing
  if ! command -v helm >/dev/null 2>&1; then
    log "Installing Helm"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/get_helm.sh" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod +x "$tmp/get_helm.sh"
    "$tmp/get_helm.sh"
    trap - EXIT
    rm -rf "$tmp"
  fi

  log "kubectl: $(kubectl version --client -o json | grep -o '"gitVersion":"[^"]*"' | head -1 || echo 'unknown')"
  log "helm: $(helm version --short 2>/dev/null || echo 'unknown')"
}

prompt_secrets() {
  log "Collecting secrets (input is hidden)"

  # ArgoCD admin password
  printf "ArgoCD admin password: "
  read -rs ARGOCD_PASSWORD
  printf "\n"
  if [[ -z "${ARGOCD_PASSWORD}" ]]; then
    err "ArgoCD password is required"
  fi

  # Tailscale OAuth credentials
  printf "Tailscale OAuth Client ID: "
  read -rs TS_CLIENT_ID
  printf "\n"
  if [[ -z "${TS_CLIENT_ID}" ]]; then
    err "Tailscale OAuth Client ID is required"
  fi

  printf "Tailscale OAuth Client Secret: "
  read -rs TS_CLIENT_SECRET
  printf "\n"
  if [[ -z "${TS_CLIENT_SECRET}" ]]; then
    err "Tailscale OAuth Client Secret is required"
  fi
}

create_secrets() {
  log "Creating pre-bootstrap secrets"

  # Check for htpasswd (needed for bcrypt hashing)
  if ! command -v htpasswd >/dev/null 2>&1; then
    err "htpasswd is required for password hashing. Install apache2-utils (Linux) or it's included with macOS."
  fi

  # Hash the ArgoCD password with bcrypt
  local argocd_password_hash
  argocd_password_hash=$(htpasswd -nbBC 10 "" "${ARGOCD_PASSWORD}" | tr -d ':\n')

  # ArgoCD namespace and secret
  log "Creating ArgoCD admin secret"
  kubectl create namespace argocd \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic argocd-secret \
    -n argocd \
    --from-literal=admin.password="${argocd_password_hash}" \
    --from-literal=admin.passwordMtime="$(date +%FT%T%Z)" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Tailscale namespace and secret
  log "Creating Tailscale operator OAuth secret"
  kubectl create namespace tailscale \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic operator-oauth \
    -n tailscale \
    --from-literal=client_id="${TS_CLIENT_ID}" \
    --from-literal=client_secret="${TS_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

bootstrap_argocd() {
  log "Setting up Helm repositories"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update
  helm repo update

  log "Building Helm dependencies for ArgoCD"
  helm dependency update "${KUBERNETES_DIR}/infra/argocd"

  log "Installing ArgoCD"
  # Use upgrade --install for idempotency (installs if missing, upgrades if exists)
  helm upgrade --install argocd "${KUBERNETES_DIR}/infra/argocd" \
    -n argocd \
    --wait \
    --timeout 5m

  log "Waiting for ArgoCD deployments to be ready"
  local deployments=(
    argocd-application-controller
    argocd-repo-server
    argocd-server
    argocd-applicationset-controller
    argocd-redis
  )

  for deploy in "${deployments[@]}"; do
    if kubectl -n argocd get deploy "${deploy}" >/dev/null 2>&1; then
      kubectl -n argocd rollout status deploy/"${deploy}" --timeout=5m
    else
      warn "Deployment '${deploy}' not found (skipping)"
    fi
  done
}

apply_gitops() {
  log "Applying root GitOps application"
  kubectl apply -f "${KUBERNETES_DIR}/applications.yaml"
}

verify_cluster() {
  log "Verifying cluster state"

  printf "\nNodes:\n"
  kubectl get nodes -o wide

  printf "\nArgoCD Applications:\n"
  kubectl get applications -n argocd 2>/dev/null || echo "  (none yet - ArgoCD is syncing)"

  printf "\nPods in argocd namespace:\n"
  kubectl get pods -n argocd

  printf "\nPods in tailscale namespace:\n"
  kubectl get pods -n tailscale 2>/dev/null || echo "  (namespace may not exist yet)"
}

print_summary() {
  log "Bootstrap complete!"

  printf "\nArgoCD is now syncing your infrastructure. This may take a few minutes.\n"
  printf "\nTo check sync status:\n"
  printf "  kubectl get applications -n argocd\n"
  printf "\nOnce the tailscale-operator application is synced, ArgoCD UI will be available at:\n"
  printf "  https://argocd.<your-tailnet>.ts.net\n"
  printf "\nLogin with:\n"
  printf "  Username: admin\n"
  printf "  Password: (the password you entered during this script)\n"
}

main() {
  check_dependencies
  prompt_secrets
  create_secrets
  bootstrap_argocd
  apply_gitops
  verify_cluster
  print_summary
}

main "$@"
