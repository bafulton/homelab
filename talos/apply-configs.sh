#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Talos Config Applier
# ============================================================================
#
# Applies generated Talos configs to nodes on the local network.
# Run this after flashing images and booting nodes.
#
# Usage: ./apply-configs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"

log()  { printf "\n==> %s\n" "$*"; }
err()  { printf "\n[error] %s\n" "$*" >&2; exit 1; }

check_dependencies() {
  if ! command -v talosctl >/dev/null 2>&1; then
    err "talosctl is required but not installed. See: https://www.talos.dev/latest/introduction/getting-started/#talosctl"
  fi
}

check_generated_configs() {
  if [[ ! -d "${GENERATED_DIR}" ]]; then
    err "Generated configs not found. Run ./generate-configs.sh first."
  fi

  if [[ ! -f "${GENERATED_DIR}/controlplane.yaml" ]]; then
    err "controlplane.yaml not found in ${GENERATED_DIR}. Run ./generate-configs.sh first."
  fi
}

discover_configs() {
  # Find all generated config files
  CONTROLPLANE_CONFIG="${GENERATED_DIR}/controlplane.yaml"

  WORKER_CONFIGS=()
  for f in "${GENERATED_DIR}"/worker-*.yaml; do
    [[ -f "$f" ]] && WORKER_CONFIGS+=("$f")
  done
}

prompt_ips() {
  log "Enter LAN IPs for each node"
  printf "\nNodes need to be booted and on your local network.\n"
  printf "Find them with: talosctl disks --insecure --nodes 192.168.x.x\n\n"

  # Control plane
  local cp_name
  cp_name=$(basename "${CONTROLPLANE_CONFIG}" .yaml)
  printf "LAN IP for control plane (%s): " "${cp_name}"
  read -r CONTROLPLANE_IP
  if [[ -z "${CONTROLPLANE_IP}" ]]; then
    err "Control plane IP is required"
  fi

  # Workers
  WORKER_IPS=()
  for config in "${WORKER_CONFIGS[@]}"; do
    local worker_name
    worker_name=$(basename "${config}" .yaml | sed 's/^worker-//')
    printf "LAN IP for %s: " "${worker_name}"
    read -r ip
    if [[ -z "${ip}" ]]; then
      err "IP for ${worker_name} is required"
    fi
    WORKER_IPS+=("${ip}")
  done
}

confirm_apply() {
  log "Configuration Summary"

  printf "\n  Control plane:\n"
  printf "    %s → %s\n" "${CONTROLPLANE_IP}" "${CONTROLPLANE_CONFIG}"

  if (( ${#WORKER_CONFIGS[@]} > 0 )); then
    printf "\n  Workers:\n"
    for i in "${!WORKER_CONFIGS[@]}"; do
      printf "    %s → %s\n" "${WORKER_IPS[$i]}" "${WORKER_CONFIGS[$i]}"
    done
  fi

  printf "\nApply configs? [Y/n] "
  read -r confirm
  if [[ "${confirm,,}" == "n" ]]; then
    err "Aborted by user"
  fi
}

apply_configs() {
  log "Applying control plane config"
  talosctl apply-config --insecure \
    --nodes "${CONTROLPLANE_IP}" \
    --file "${CONTROLPLANE_CONFIG}"

  for i in "${!WORKER_CONFIGS[@]}"; do
    local worker_name
    worker_name=$(basename "${WORKER_CONFIGS[$i]}" .yaml | sed 's/^worker-//')
    log "Applying config for ${worker_name}"
    talosctl apply-config --insecure \
      --nodes "${WORKER_IPS[$i]}" \
      --file "${WORKER_CONFIGS[$i]}"
  done
}

print_summary() {
  log "Configs applied!"

  printf "\nNodes will now reboot and Tailscale will come up.\n"
  printf "This may take a few minutes.\n"
  printf "\nOnce nodes are back online, run:\n"
  printf "  ./bootstrap.sh\n"
}

main() {
  check_dependencies
  check_generated_configs
  discover_configs
  prompt_ips
  confirm_apply
  apply_configs
  print_summary
}

main "$@"
