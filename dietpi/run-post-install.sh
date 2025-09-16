#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# DietPi Post-Install Script
# ============================================================================
#
# Reads config from /boot/post-install.env, installs Tailscale and k3s
# (server/agent), then securely deletes post-install.env.
#
# Expected variables in post-install.env:
#   TS_AUTH_KEY
#   K3S_ROLE               ("server" or "agent")
#   K3S_PASSWORD           (shared token/password for cluster)
#   K3S_SERVER_URL         (required if K3S_ROLE=agent)
#   GITOPS_REPO_URL        (required if K3S_ROLE=server)
#   BOOTSTRAP_SCRIPT_PATH  (required if K3S_ROLE=server)

ENV_FILE="$(dirname "$0")/post-install.env"

log() { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[warn]\e[0m $*"; }
err() { echo -e "\e[1;31m[err]\e[0m $*"; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "This script must run as root."
    exit 1
  fi
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err "Missing $ENV_FILE"
    exit 1
  fi
  log "Loading configuration from ${ENV_FILE}"
  # shellcheck disable=SC1090
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
}

validate_env() {
  : "${TS_AUTH_KEY:?TS_AUTH_KEY is required.}"
  : "${K3S_ROLE:?K3S_ROLE is required (server|agent).}"
  : "${K3S_PASSWORD:?K3S_PASSWORD is required.}"
  case "${K3S_ROLE}" in
    agent)
      [[ -z "${K3S_SERVER_URL:-}" ]] && { err "Agent role requires K3S_SERVER_URL"; exit 1; }
      ;;
    server)
      [[ -z "${GITOPS_REPO_URL:-}" ]] && { err "Server role requires GITOPS_REPO_URL"; exit 1; }
      [[ -z "${BOOTSTRAP_SCRIPT_PATH:-}" ]] && { err "Server role requires BOOTSTRAP_SCRIPT_PATH"; exit 1; }
      ;;
    *)
      err "K3S_ROLE must be 'server' or 'agent' (got: ${K3S_ROLE})"
      exit 1
      ;;
  esac
}

apt_install_if_missing() {
  # Usage: apt_install_if_missing pkg1 pkg2 ...
  local pkgs_to_install=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      pkgs_to_install+=("$pkg")
    fi
  done
  if (( ${#pkgs_to_install[@]} > 0 )); then
    log "Installing packages: ${pkgs_to_install[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs_to_install[@]}"
  fi
}

install_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale"
    apt_install_if_missing curl
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    log "Tailscale already installed"
  fi

  systemctl enable --now tailscaled

  # If not logged in, bring it up. Use minimal logging; do not echo key.
  if ! tailscale status --peers=false >/dev/null 2>&1; then
    log "Bringing up Tailscale (with SSH access)"
    # --reset ensures we apply the provided flags even if prior state exists.
    tailscale up --reset --ssh --auth-key "${TS_AUTH_KEY}"
  else
    log "Tailscale already up; skipping tailscale up"
  fi
}

get_tailscale_ipv4() {
  # Prefer 100.64.0.0/10 address
  local ip
  ip="$(tailscale ip -4 2>/dev/null | grep -E '^100\.' | head -n1 || true)"
  if [[ -z "$ip" ]]; then
    # fallback to first IPv4 tailscale IP
    ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
  echo "$ip"
}

install_k3s_agent() {
  local server="${K3S_SERVER_URL}"
  # Normalize to https://host:6443 if user gave just host or host:port
  if [[ "$server" != https://* ]]; then
    # strip any trailing :6443 if present, we’ll add standardized form
    server="${server%:6443}"
    server="https://${server}:6443"
  fi

  if systemctl is-active --quiet k3s-agent; then
    log "k3s agent already running; skipping install"
    return
  fi

  log "Installing k3s agent -> ${server}"
  curl -sfL https://get.k3s.io | \
    K3S_URL="${server}" \
    K3S_TOKEN="${K3S_PASSWORD}" \
    sh -

  systemctl enable --now k3s-agent
}

install_k3s_server() {
  # Determine Tailscale IP and use it as bind-address
  local ts_ip
  ts_ip="$(get_tailscale_ipv4)"
  if [[ -z "$ts_ip" ]]; then
    err "Could not determine Tailscale IPv4 address."
    exit 1
  fi

  if systemctl is-active --quiet k3s; then
    log "k3s server already running; skipping install"
  else
    log "Installing k3s server (bind ${ts_ip})"
    curl -sfL https://get.k3s.io | sh -s - \
      --write-kubeconfig-mode 644 \
      --token "${K3S_PASSWORD}" \
      --bind-address "${ts_ip}" \
      --disable-cloud-controller \
      --disable servicelb \
      --disable local-storage \
      --disable traefik \
      --disable metrics-server
    systemctl enable --now k3s
  fi
}

run_bootstrap_script() {
  apt_install_if_missing git
  local workdir="/root/gitops-$(date +%s)"  # FIX: correct path; no quoted ~
  log "Cloning GitOps repo: ${GITOPS_REPO_URL}"
  git clone --depth=1 "${GITOPS_REPO_URL}" "${workdir}"

  if [[ ! -f "${workdir}/${BOOTSTRAP_SCRIPT_PATH}" ]]; then
    err "Bootstrap script not found: ${workdir}/${BOOTSTRAP_SCRIPT_PATH}"
    exit 1
  fi

  # Optional: wait for apiserver to be responsive (avoids races on tiny Pis)
  if command -v kubectl >/dev/null 2>&1; then
    log "Waiting for Kubernetes API to become ready..."
    for i in {1..30}; do
      if kubectl get nodes >/dev/null 2>&1; then break; fi
      sleep 2
    done
  fi

  log "Running bootstrap: ${BOOTSTRAP_SCRIPT_PATH}"
  chmod +x "${workdir}/${BOOTSTRAP_SCRIPT_PATH}" || true
  (cd "${workdir}" && bash "${BOOTSTRAP_SCRIPT_PATH}")
}

secure_delete_env() {
  if [[ -f "$ENV_FILE" ]]; then
    log "Deleting ${ENV_FILE}"
    # Prefer shred if available
    if command -v shred >/dev/null 2>&1; then
      shred -u "$ENV_FILE" || rm -f "$ENV_FILE"
    else
      rm -f "$ENV_FILE"
    fi
  fi
}

main() {
  require_root
  load_env
  validate_env

  install_tailscale

  case "${K3S_ROLE}" in
    agent)
      install_k3s_agent
      ;;
    server)
      install_k3s_server
      run_bootstrap_script
      ;;
  esac

  secure_delete_env
  log "All done!"
}

main "$@"
