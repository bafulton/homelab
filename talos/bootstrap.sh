#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Talos Cluster Bootstrap Script
# ============================================================================
#
# Fully bootstraps a Talos Kubernetes cluster with GitOps infrastructure.
# Run this after applying Talos configs and nodes have rebooted.
#
# This script:
#   1. Bootstraps the Talos cluster (talosctl bootstrap)
#   2. Retrieves kubeconfig
#   3. Prompts for required secrets (ArgoCD password, Tailscale OAuth)
#   4. Creates pre-bootstrap Kubernetes secrets
#   5. Installs ArgoCD via Helm
#   6. Applies the root GitOps application
#   7. Verifies the deployment
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

  if ! command -v talosctl >/dev/null 2>&1; then
    err "talosctl is required but not installed. See: https://www.talos.dev/latest/introduction/getting-started/#talosctl"
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    err "kubectl is required but not installed. See: https://kubernetes.io/docs/tasks/tools/"
  fi

  log "talosctl: $(talosctl version --client 2>/dev/null | grep -o 'Tag:.*' | head -1 || echo 'unknown')"
  log "kubectl: $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1 || echo 'unknown')"
}

check_talos_reachable() {
  log "Checking Talos API is reachable"

  if ! talosctl version >/dev/null 2>&1; then
    err "Cannot reach Talos API. Make sure:
  1. Nodes have rebooted after apply-configs.sh
  2. Tailscale is running on the nodes
  3. Your talosctl config points to the correct endpoint
     (Run: talosctl config info)"
  fi
}

bootstrap_talos() {
  log "Bootstrapping Talos cluster"

  # Check if already bootstrapped by verifying etcd is running
  local etcd_state
  etcd_state=$(talosctl services 2>/dev/null | grep -E '^\S+\s+etcd\s+' | awk '{print $3}')

  if [[ "${etcd_state}" == "Running" ]]; then
    log "Cluster already bootstrapped (etcd is running), skipping talosctl bootstrap"
  else
    talosctl bootstrap
    log "Waiting for etcd to start..."
    # Wait for etcd to be running
    local retries=30
    while true; do
      etcd_state=$(talosctl services 2>/dev/null | grep -E '^\S+\s+etcd\s+' | awk '{print $3}')
      if [[ "${etcd_state}" == "Running" ]]; then
        break
      fi
      retries=$((retries - 1))
      if [[ ${retries} -le 0 ]]; then
        err "Timed out waiting for etcd to start"
      fi
      sleep 5
    done
    log "etcd is running"
  fi
}

get_kubeconfig() {
  log "Retrieving kubeconfig"

  local kubeconfig_path="${HOME}/.kube/config"
  mkdir -p "$(dirname "${kubeconfig_path}")"

  # Backup existing kubeconfig if present
  if [[ -f "${kubeconfig_path}" ]]; then
    local backup="${kubeconfig_path}.backup.$(date +%Y%m%d%H%M%S)"
    log "Backing up existing kubeconfig to ${backup}"
    cp "${kubeconfig_path}" "${backup}"
  fi

  talosctl kubeconfig -f "${kubeconfig_path}"
  log "Kubeconfig written to ${kubeconfig_path}"

  # Wait for cluster to be accessible
  log "Waiting for cluster to be accessible..."
  local retries=30
  while ! kubectl cluster-info >/dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ ${retries} -le 0 ]]; then
      err "Timed out waiting for cluster to be accessible"
    fi
    sleep 5
  done
}

install_helm() {
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

  # Bitwarden Secrets Manager access token
  printf "Bitwarden Secrets Manager Access Token (or press Enter to skip): "
  read -rs BW_ACCESS_TOKEN
  printf "\n"
  # This one is optional - external-secrets will be degraded without it but cluster still works
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

  # Bitwarden Secrets Manager access token (optional)
  if [[ -n "${BW_ACCESS_TOKEN}" ]]; then
    log "Creating Bitwarden Secrets Manager access token"
    kubectl create namespace external-secrets \
      --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic bitwarden-access-token \
      -n external-secrets \
      --from-literal=token="${BW_ACCESS_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    warn "Skipping Bitwarden secret - external-secrets will be degraded until manually configured"
  fi
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
  check_talos_reachable
  bootstrap_talos
  get_kubeconfig
  install_helm
  prompt_secrets
  create_secrets
  bootstrap_argocd
  apply_gitops
  verify_cluster
  print_summary
}

main "$@"
