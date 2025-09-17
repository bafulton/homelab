#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# DietPi Post-Install Script
# ============================================================================
#
# Reads config from /post-install.env, installs Tailscale and k3s
# (server/agent), then securely deletes post-install.env.
#
# Expected variables in post-install.env:
#   TS_AUTH_KEY
#   K3S_ROLE               ("server" or "agent")
#   K3S_PASSWORD           (shared token/password for cluster)
#   K3S_SERVER_URL         (required if K3S_ROLE=agent)
#   GITOPS_REPO_URL        (required if K3S_ROLE=server)
#   BOOTSTRAP_SCRIPT_PATH  (required if K3S_ROLE=server)

ENV_FILE="/boot/firmware/post-install.env"

log()  { printf "\n==> $*\n"; }
warn() { printf "\n[warn] $*\n"; }
err()  { printf "\n[err]  $*\n" >&2; exit 1; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "This script must run as root."
  fi
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err "Missing $ENV_FILE"
  fi
  log "Loading configuration from ${ENV_FILE}"
  # shellcheck disable=SC1090
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
}

validate_env() {
  log "Validating env vars"

  [[ -n "${TS_AUTH_KEY:-}"   ]] || err "TS_AUTH_KEY is required."
  [[ -n "${K3S_ROLE:-}"      ]] || err "K3S_ROLE is required (server|agent)."
  [[ -n "${K3S_PASSWORD:-}"  ]] || err "K3S_PASSWORD is required."

  case "${K3S_ROLE}" in
    agent)
      [[ -n "${K3S_SERVER_URL:-}" ]] || err "Agent role requires K3S_SERVER_URL"
      ;;
    server)
      [[ -n "${GITOPS_REPO_URL:-}"       ]] || err "Server role requires GITOPS_REPO_URL"
      [[ -n "${BOOTSTRAP_SCRIPT_PATH:-}" ]] || err "Server role requires BOOTSTRAP_SCRIPT_PATH"
      [[ -n "${TS_CLIENT_ID:-}"          ]] || err "Server role requires TS_CLIENT_ID"
      [[ -n "${TS_CLIENT_SECRET:-}"      ]] || err "Server role requires TS_CLIENT_SECRET"
      ;;
    *)
      err "K3S_ROLE must be 'server' or 'agent' (got: ${K3S_ROLE@Q})"
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

  # Wait for a tailscale IP
  for i in {1..15}; do
    if tailscale ip -4 | grep -qE '^[0-9]'; then break; fi
    sleep 1
  done
}

get_tailscale_ipv4() {
  # Prefer 100.64.0.0/10 address
  local ip
  ip="$(tailscale ip -4 2>/dev/null | grep -E '^100\.' | head -n1 || true)"
  if [[ -z "$ip" ]]; then
    # fallback to first IPv4 tailscale IP
    ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$ip" ]] || err "Could not determine Tailscale IPv4 address."
  echo "$ip"
}

install_k3s_agent() {
  local ts_ip="$(get_tailscale_ipv4)"

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
  curl -sfL https://get.k3s.io | sh -s - agent \
    --server "${server}" \
    --token "${K3S_PASSWORD}" \
    --node-ip "${ts_ip}"
}

install_k3s_server() {
  local ts_ip="$(get_tailscale_ipv4)"

  if systemctl is-active --quiet k3s; then
    log "k3s server already running; skipping install"
  else
    log "Installing k3s server (bind ${ts_ip})"
    curl -sfL https://get.k3s.io | sh -s - \
      --write-kubeconfig-mode 644 \
      --token "${K3S_PASSWORD}" \
      --bind-address "${ts_ip}" \
      --node-ip "${ts_ip}" \
      --tls-san "${ts_ip}" \
      --disable-cloud-controller \
      --disable servicelb \
      --disable local-storage \
      --disable traefik \
      --disable metrics-server

    # wait for apiserver to be responsive
    if command -v kubectl >/dev/null 2>&1; then
      log "Waiting for Kubernetes API to become ready..."
      for i in {1..30}; do
        if kubectl get nodes >/dev/null 2>&1; then break; fi
        sleep 2
      done
    fi
  fi
}

create_kubernetes_secrets() {
  log "Creating a secret for the Argo CD admin password"

  apt_install_if_missing apache2-utils
  argocd_password_hash=$(
    htpasswd -nbBC 10 "" "$ARGOCD_PASSWORD" | tr -d ':\n'
  )

  kubectl create namespace argocd \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic argocd-secret \
    -n argocd \
    --from-literal=admin.password="$argocd_password_hash" \
    --from-literal=admin.passwordMtime="$(date +%FT%T%Z)" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Creating a secret for Tailscale Operator's client credentials"

  kubectl create namespace tailscale \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic operator-oauth \
    -n tailscale \
    --from-literal=client_id="$TS_CLIENT_ID" \
    --from-literal=client_secret="$TS_CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
}

run_bootstrap_script() {
  apt_install_if_missing git

  local repo_dir="${HOME}/gitops"
  local script_path="${repo_dir}/${BOOTSTRAP_SCRIPT_PATH}"

  log "Cloning GitOps repo: ${GITOPS_REPO_URL}"
  git clone --depth=1 "${GITOPS_REPO_URL}" "${repo_dir}"

  if [[ ! -f "${script_path}" ]]; then
    err "Bootstrap script not found: ${script_path}"
  fi

  log "Running bootstrap: ${script_path}"
  (cd "${repo_dir}" && bash "${BOOTSTRAP_SCRIPT_PATH}")
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

  # tailscale and k3s installs need curl
  apt_install_if_missing curl

  install_tailscale

  case "${K3S_ROLE}" in
    agent)
      install_k3s_agent
      ;;
    server)
      install_k3s_server
      create_kubernetes_secrets
      run_bootstrap_script
      ;;
  esac

  secure_delete_env
  log "All done!"
}

main "$@"
