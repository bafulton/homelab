#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Talos Config Generator (Talhelper Wrapper)
# ============================================================================
#
# Generates Talos machine configs using Talhelper.
# Configuration is defined in talconfig.yaml, secrets in .env file.
#
# Usage: ./generate-configs.sh
#
# Prerequisites:
#   - talhelper: brew install budimanjojo/tap/talhelper
#   - talosctl:  brew install siderolabs/tap/talosctl
#   - .env file with TS_AUTHKEY and TAILNET_NAME

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
SECRETS_FILE="${SCRIPT_DIR}/talsecret.yaml"
OUTPUT_DIR="${SCRIPT_DIR}/clusterconfig"

log()  { printf "\n==> %s\n" "$*"; }
err()  { printf "\n[error] %s\n" "$*" >&2; exit 1; }

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    err "Missing .env file. Copy .env.example to .env and fill in your values."
  fi

  log "Loading environment from .env file"
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a

  # Validate required variables
  if [[ -z "${TS_AUTHKEY:-}" ]]; then
    err "TS_AUTHKEY is required in .env file"
  fi
  if [[ -z "${TAILNET_NAME:-}" ]]; then
    err "TAILNET_NAME is required in .env file"
  fi
}

check_dependencies() {
  local missing=()
  command -v talhelper >/dev/null 2>&1 || missing+=("talhelper (brew install budimanjojo/tap/talhelper)")
  command -v talosctl >/dev/null 2>&1 || missing+=("talosctl (brew install siderolabs/tap/talosctl)")

  if (( ${#missing[@]} > 0 )); then
    err "Missing required tools:\n  ${missing[*]}"
  fi

  if [[ ! -f "${SCRIPT_DIR}/talconfig.yaml" ]]; then
    err "talconfig.yaml not found in ${SCRIPT_DIR}"
  fi
}

generate_secrets() {
  if [[ -f "${SECRETS_FILE}" ]]; then
    log "Using existing secrets from ${SECRETS_FILE}"
  else
    log "Generating new cluster secrets"
    talhelper gensecret > "${SECRETS_FILE}"
    printf "  Created: %s\n" "${SECRETS_FILE}"
    printf "  IMPORTANT: Back up this file securely - it contains cluster CA & keys!\n"
  fi
}

generate_configs() {
  log "Generating Talos configs with Talhelper"

  cd "${SCRIPT_DIR}"
  talhelper genconfig

  printf "\nGenerated configs in %s/\n" "${OUTPUT_DIR}"
}

install_talosconfig() {
  local talos_dir="${HOME}/.talos"
  local config_file="${talos_dir}/config"
  local generated_config="${OUTPUT_DIR}/talosconfig"

  if [[ ! -f "${generated_config}" ]]; then
    err "talosconfig not found at ${generated_config}"
  fi

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

  # Copy the generated talosconfig
  cp "${generated_config}" "${config_file}"

  # Configure endpoint and node (control plane hostname from talconfig)
  local endpoint="beelink.${TAILNET_NAME}.ts.net"
  talosctl config endpoint "${endpoint}"
  talosctl config node "${endpoint}"

  log "talosconfig installed and configured for ${endpoint}"
}

print_summary() {
  log "Config generation complete!"

  printf "\nGenerated files:\n"
  for f in "${OUTPUT_DIR}"/*.yaml; do
    if [[ -f "$f" ]]; then
      printf "  %s\n" "$f"
    fi
  done
  printf "  %s/talosconfig\n" "${OUTPUT_DIR}"
  printf "\nSecrets file (back up securely!):\n"
  printf "  %s\n" "${SECRETS_FILE}"

  printf "\nNext steps:\n"
  printf "  1. Boot your Talos nodes\n"
  printf "  2. Run: ./apply-configs.sh\n"
}

main() {
  load_env
  check_dependencies
  generate_secrets
  generate_configs
  install_talosconfig
  print_summary
}

main "$@"
