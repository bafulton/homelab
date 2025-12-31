#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Talos Config Generator
# ============================================================================
#
# Generates Talos machine configs for a homelab Kubernetes cluster.
# Prompts for configuration interactively, or reads from .env file.
#
# Usage: ./generate-configs.sh
#
# Optional: Create a .env file with secrets to avoid interactive prompts:
#   TS_AUTHKEY=tskey-auth-xxxxx

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="${SCRIPT_DIR}/patches"
OUTPUT_DIR="${SCRIPT_DIR}/generated"
ENV_FILE="${SCRIPT_DIR}/.env"
SECRETS_FILE="${OUTPUT_DIR}/secrets.yaml"

CLUSTER_NAME="homelab"

log()  { printf "\n==> %s\n" "$*"; }
err()  { printf "\n[error] %s\n" "$*" >&2; exit 1; }

load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    log "Loading environment from .env file"
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
  fi
}

check_dependencies() {
  local missing=()
  command -v talosctl >/dev/null 2>&1 || missing+=("talosctl")
  command -v envsubst >/dev/null 2>&1 || missing+=("envsubst (gettext)")

  if (( ${#missing[@]} > 0 )); then
    err "Missing required tools: ${missing[*]}"
  fi

  # Check for patches directory
  if [[ ! -d "${PATCHES_DIR}" ]]; then
    err "Patches directory not found: ${PATCHES_DIR}"
  fi
  if [[ ! -f "${PATCHES_DIR}/controlplane.yaml" ]]; then
    err "Control plane patch not found: ${PATCHES_DIR}/controlplane.yaml"
  fi
  if [[ ! -f "${PATCHES_DIR}/worker.yaml" ]]; then
    err "Worker patch not found: ${PATCHES_DIR}/worker.yaml"
  fi
}

prompt_config() {
  log "Cluster Configuration"

  # Tailnet name
  printf "Tailscale tailnet name (e.g., catfish-mountain): "
  read -r TAILNET_NAME
  if [[ -z "${TAILNET_NAME}" ]]; then
    err "Tailnet name is required"
  fi
  # Strip .ts.net suffix if user accidentally included it
  TAILNET_NAME="${TAILNET_NAME%.ts.net}"
  export TAILNET_NAME

  # Control plane hostname
  printf "Control plane node hostname (e.g., beelink): "
  read -r CONTROLPLANE_HOSTNAME
  if [[ -z "${CONTROLPLANE_HOSTNAME}" ]]; then
    err "Control plane hostname is required"
  fi
  export CONTROLPLANE_HOSTNAME

  # Derive the cluster endpoint
  CLUSTER_ENDPOINT="https://${CONTROLPLANE_HOSTNAME}.${TAILNET_NAME}.ts.net:6443"
  export CLUSTER_ENDPOINT

  # Worker hostnames (optional - can be empty for single-node cluster)
  printf "Worker node hostnames (space-separated, e.g., rpi3 rpi5, or leave empty): "
  read -r worker_input
  if [[ -n "${worker_input}" ]]; then
    read -r -a WORKER_HOSTNAMES <<< "${worker_input}"
  else
    WORKER_HOSTNAMES=()
  fi
}

prompt_secrets() {
  log "Secrets"

  # Skip prompt if already set (e.g., from .env file)
  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    printf "  Tailscale Auth Key: (loaded from .env)\n"
  else
    printf "Tailscale Auth Key (hidden): "
    read -rs TS_AUTHKEY
    printf "\n"

    if [[ -z "${TS_AUTHKEY}" ]]; then
      err "Tailscale auth key is required"
    fi
  fi

  export TS_AUTHKEY
}

confirm_config() {
  log "Configuration Summary"

  printf "  Tailnet:        %s.ts.net\n" "${TAILNET_NAME}"
  printf "  Control plane:  %s\n" "${CONTROLPLANE_HOSTNAME}"
  if (( ${#WORKER_HOSTNAMES[@]} > 0 )); then
    printf "  Workers:        %s\n" "${WORKER_HOSTNAMES[*]}"
  else
    printf "  Workers:        (none - single node cluster)\n"
  fi
  printf "  Cluster endpoint: %s\n" "${CLUSTER_ENDPOINT}"

  printf "\nProceed? [Y/n] "
  read -r confirm
  if [[ "${confirm}" =~ ^[Nn]$ ]]; then
    err "Aborted by user"
  fi
}

generate_patches() {
  log "Processing patches with envsubst"

  mkdir -p "${OUTPUT_DIR}"

  # Control plane patch
  HOSTNAME="${CONTROLPLANE_HOSTNAME}" \
    envsubst '${TS_AUTHKEY} ${HOSTNAME} ${TAILNET_NAME}' \
    < "${PATCHES_DIR}/controlplane.yaml" \
    > "${OUTPUT_DIR}/controlplane-patch.yaml"

  # Worker patches (one per node)
  for hostname in "${WORKER_HOSTNAMES[@]}"; do
    HOSTNAME="${hostname}" \
      envsubst '${TS_AUTHKEY} ${HOSTNAME} ${TAILNET_NAME}' \
      < "${PATCHES_DIR}/worker.yaml" \
      > "${OUTPUT_DIR}/worker-${hostname}-patch.yaml"
  done
}

generate_talos_configs() {
  log "Generating Talos configs for cluster: ${CLUSTER_NAME}"

  # Generate or reuse cluster secrets
  if [[ -f "${SECRETS_FILE}" ]]; then
    log "Using existing secrets from ${SECRETS_FILE}"
  else
    log "Generating new cluster secrets"
    mkdir -p "${OUTPUT_DIR}"
    talosctl gen secrets -o "${SECRETS_FILE}"
  fi

  # Generate control plane config
  talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
    --output-dir "${OUTPUT_DIR}" \
    --with-secrets "${SECRETS_FILE}" \
    --config-patch-control-plane "@${OUTPUT_DIR}/controlplane-patch.yaml" \
    --force

  # Generate worker configs (one per node)
  for hostname in "${WORKER_HOSTNAMES[@]}"; do
    log "Generating worker config for ${hostname}"

    talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
      --output-dir "${OUTPUT_DIR}" \
      --with-secrets "${SECRETS_FILE}" \
      --output-types worker \
      --config-patch-worker "@${OUTPUT_DIR}/worker-${hostname}-patch.yaml" \
      --force

    mv "${OUTPUT_DIR}/worker.yaml" "${OUTPUT_DIR}/worker-${hostname}.yaml"
  done
}

cleanup_patches() {
  # Remove intermediate patch files (they contain secrets)
  rm -f "${OUTPUT_DIR}"/*-patch.yaml
}

install_talosconfig() {
  local talos_dir="${HOME}/.talos"
  local config_file="${talos_dir}/config"
  local endpoint="${CONTROLPLANE_HOSTNAME}.${TAILNET_NAME}.ts.net"

  printf "\nInstall talosconfig to %s? [Y/n] " "${config_file}"
  read -r install_confirm
  if [[ "${install_confirm}" =~ ^[Nn]$ ]]; then
    log "Skipping talosconfig installation"
    return
  fi

  # Backup existing config if present
  if [[ -f "${config_file}" ]]; then
    local backup="${config_file}.backup.$(date +%Y%m%d%H%M%S)"
    log "Backing up existing config to ${backup}"
    cp "${config_file}" "${backup}"
  fi

  # Create directory if needed
  mkdir -p "${talos_dir}"

  # Copy and configure
  cp "${OUTPUT_DIR}/talosconfig" "${config_file}"
  talosctl config endpoint "${endpoint}"
  talosctl config node "${endpoint}"

  log "talosconfig installed and configured for ${endpoint}"
}

print_summary() {
  log "Config generation complete!"

  printf "\nGenerated files:\n"
  printf "  %s/controlplane.yaml  (%s)\n" "${OUTPUT_DIR}" "${CONTROLPLANE_HOSTNAME}"
  for hostname in "${WORKER_HOSTNAMES[@]}"; do
    printf "  %s/worker-%s.yaml\n" "${OUTPUT_DIR}" "${hostname}"
  done
  printf "  %s/talosconfig\n" "${OUTPUT_DIR}"
  printf "  %s/secrets.yaml  (cluster CA & keys - back up securely!)\n" "${OUTPUT_DIR}"
}

main() {
  load_env
  check_dependencies
  prompt_config
  prompt_secrets
  confirm_config
  generate_patches
  generate_talos_configs
  cleanup_patches
  install_talosconfig
  print_summary
}

main "$@"
