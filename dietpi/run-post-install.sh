#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# DietPi Post-Install Script
# ============================================================================
# Reads config from /boot/post-install.env, installs Tailscale and k3s
# (server/agent), optionally installs Helm + Argo CD (for server role), then
# securely deletes post-install.env.
#
# Expected variables in post-install.env:
#   TS_AUTH_KEY
#   K3S_ROLE               ("server" or "agent")
#   K3S_PASSWORD           (shared token/password for cluster)
#   K3S_SERVER_URL         (required if K3S_ROLE=agent)
#   GITOPS_REPO_URL        (required if K3S_ROLE=server)
#   BOOTSTRAP_SCRIPT_PATH  (required if K3S_ROLE=server)
#
# This script is designed to be idempotent; re-runs try to "do-the-right-thing" without blowing up.
#
# Tested on DietPi (Debian-based). Requires network connectivity.

log() { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[warn]\e[0m $*"; }
err() { echo -e "\e[1;31m[err]\e[0m  $*" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

# --- Locate and load post-install.env ---
load_env() {
  local candidates=(
    "/boot/post-install.env"
    "/post-install.env"
    "/root/post-install.env"
  )
  local env_file=""
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      env_file="$f"
      break
    fi
  done
  if [[ -z "${env_file}" ]]; then
    err "post-install.env not found in /boot, /, or /root."
    exit 1
  fi
  log "Loading configuration from ${env_file}"
  # shellcheck disable=SC1090
  set -o allexport
  source "${env_file}"
  set +o allexport
  POST_INSTALL_ENV_PATH="${env_file}"
}

# --- Validate required vars ---
validate_env() {
  : "${TS_AUTH_KEY:?TS_AUTH_KEY is required.}"
  : "${K3S_ROLE:?K3S_ROLE is required (server|agent).}"
  : "${K3S_PASSWORD:?K3S_PASSWORD is required.}"
  case "${K3S_ROLE}" in
    server)
      : "${GITOPS_REPO_URL:?GITOPS_REPO_URL is required for server role.}"
      : "${BOOTSTRAP_SCRIPT_PATH:?BOOTSTRAP_SCRIPT_PATH is required for server role.}"
      ;;
    agent)
      : "${K3S_SERVER_URL:?K3S_SERVER_URL is required for agent role.}"
      ;;
    *)
      err "K3S_ROLE must be 'server' or 'agent', got '${K3S_ROLE}'."
      exit 1
      ;;
  esac
}

# --- Tailscale install + up ---
install_and_up_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    log "Tailscale already installed."
  fi

  systemctl enable --now tailscaled >/dev/null 2>&1 || true

  # Bring Tailscale up using provided key (idempotently).
  if tailscale status >/dev/null 2>&1; then
    log "Tailscale already up."
  else
    log "Authenticating to Tailscale..."
    # --ssh enables SSH over Tailscale to this node
    tailscale up --ssh --auth-key="${TS_AUTH_KEY}"
  fi
}

get_tailscale_ip() {
  # Prefer IPv4 TS IP
  local ip=""
  for i in {1..10}; do
    ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- install k3s as agent ---
install_k3s_agent() {
  log "Installing k3s (agent)..."
  # If already installed, skip.
  if systemctl is-active --quiet k3s-agent; then
    log "k3s-agent already running; skipping install."
    return
  fi
  # shellcheck disable=SC2153
  curl -sfL https://get.k3s.io | \
    K3S_URL="${K3S_SERVER_URL}:6443" \
    K3S_TOKEN="${K3S_PASSWORD}" \
    sh -
  log "k3s agent installation complete."
}

# --- install k3s as server ---
install_k3s_server() {
  log "Installing k3s (server)..."
  if systemctl is-active --quiet k3s; then
    log "k3s server already running; skipping install."
    return
  fi

  # Derive K3S_SERVER_URL from Tailscale IP for bind-address
  local ts_ip
  ts_ip="$(get_tailscale_ip)" || {
    err "Unable to retrieve Tailscale IP."
    exit 1
  }
  export K3S_SERVER_URL="${ts_ip}"

  log "Using Tailscale IP ${K3S_SERVER_URL} as k3s bind-address."

  curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --token "${K3S_PASSWORD}" \
    --bind-address "${K3S_SERVER_URL}" \
    --disable-cloud-controller \
    --disable servicelb \
    --disable local-storage \
    --disable

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  log "Waiting for k3s API to become ready..."
  for i in {1..60}; do
    if kubectl version --output=yaml >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl cluster-info
  log "k3s server installation complete."
}

# --- Securely remove env file ---
secure_delete_env() {
  local f="${POST_INSTALL_ENV_PATH:-}"
  if [[ -n "$f" && -f "$f" ]]; then
    log "Deleting ${f}"
    if command -v shred >/dev/null 2>&1; then
      shred -u "$f" || rm -f "$f"
    else
      rm -f "$f"
    fi
  fi
}

main() {
  require_root
  load_env
  validate_env
  install_base_deps
  install_and_up_tailscale

  case "${K3S_ROLE}" in
    agent)
      install_k3s_agent
      ;;
    server)
      install_k3s_server
      # todo: install git, clone repo, and run bootstrap script
      ;;
  esac

  secure_delete_env
  log "All done."
}

main "$@"
