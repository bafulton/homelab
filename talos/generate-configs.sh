#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Talos Config Generator
# ============================================================================
#
# Generates one machine config per node with `talosctl gen config`.
# Nodes and versions are defined in cluster.yaml, machine config in patches/,
# secrets in .env. Each node's config is the generated base for its role plus,
# in order: patches/all.yaml, patches/controlplane.yaml (control plane only)
# and patches/nodes/<node>.yaml.
#
# Usage: ./generate-configs.sh
#
# Prerequisites:
#   - talosctl: brew install siderolabs/tap/talosctl
#   - yq:       brew install yq
#   - envsubst: brew install gettext
#   - .env file with TS_CLIENT_ID, TS_CLIENT_SECRET and the *_DISK paths

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CLUSTER_FILE="${SCRIPT_DIR}/cluster.yaml"
PATCH_DIR="${SCRIPT_DIR}/patches"
SECRETS_FILE="${SCRIPT_DIR}/secrets.yaml"
OUTPUT_DIR="${SCRIPT_DIR}/clusterconfig"

# Only these are substituted into patches; any other ${...} is left alone.
ENV_VARS=(TS_CLIENT_ID TS_CLIENT_SECRET BEELINK_NVME_DISK BEELINK_USB_DISK RPI5_USB_DISK)

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

  local var
  for var in "${ENV_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      err "${var} is required in .env file"
    fi
  done
}

check_dependencies() {
  local missing=()
  command -v talosctl >/dev/null 2>&1 || missing+=("talosctl (brew install siderolabs/tap/talosctl)")
  command -v yq >/dev/null 2>&1 || missing+=("yq (brew install yq)")
  command -v envsubst >/dev/null 2>&1 || missing+=("envsubst (brew install gettext)")

  if (( ${#missing[@]} > 0 )); then
    err "Missing required tools:\n  ${missing[*]}"
  fi

  if [[ ! -f "${CLUSTER_FILE}" ]]; then
    err "cluster.yaml not found in ${SCRIPT_DIR}"
  fi
}

generate_secrets() {
  if [[ -f "${SECRETS_FILE}" ]]; then
    log "Using existing secrets from ${SECRETS_FILE}"
  else
    log "Generating new cluster secrets"
    talosctl gen secrets -o "${SECRETS_FILE}"
    chmod 600 "${SECRETS_FILE}"
    printf "  Created: %s\n" "${SECRETS_FILE}"
    printf "  IMPORTANT: Back up this file securely - it contains cluster CA & keys!\n"
  fi
}

# Writes patch $1 with the .env values filled in to $2.
render_patch() {
  envsubst "$(printf '${%s} ' "${ENV_VARS[@]}")" < "$1" > "$2"
}

generate_configs() {
  log "Generating Talos configs with talosctl"

  local cluster_name endpoint talos_version kubernetes_version layout
  cluster_name=$(yq -r '.clusterName' "${CLUSTER_FILE}")
  endpoint=$(yq -r '.endpoint' "${CLUSTER_FILE}")
  talos_version=$(yq -r '.talosVersion' "${CLUSTER_FILE}")
  kubernetes_version=$(yq -r '.kubernetesVersion' "${CLUSTER_FILE}")
  layout=$(yq -r '.configLayout' "${CLUSTER_FILE}")

  # gen config fills defaults from the client's own Talos version, so a client
  # behind the nodes can emit a config that differs from what they run.
  local client_version
  client_version=$(talosctl version --client --short | awk '/Talos/ {print $2}')
  if [[ "${client_version}" != "${talos_version}" ]]; then
    printf "  [warn] talosctl is %s but cluster.yaml says %s; download the matching\n" "${client_version}" "${talos_version}"
    printf "         release from github.com/siderolabs/talos/releases if Homebrew lags.\n"
  fi

  # Clean output directory to remove stale configs from previous runs
  rm -rf "${OUTPUT_DIR}"
  mkdir -p "${OUTPUT_DIR}"
  chmod 700 "${OUTPUT_DIR}"

  # Rendered patches hold the Tailscale credentials; keep them out of the repo.
  local rendered
  rendered=$(mktemp -d)
  # shellcheck disable=SC2064  # expand now: rendered is local, the trap runs at exit
  trap "rm -rf '${rendered}'" EXIT

  render_patch "${PATCH_DIR}/all.yaml" "${rendered}/all.yaml"
  render_patch "${PATCH_DIR}/controlplane.yaml" "${rendered}/controlplane.yaml"

  local common=(
    "${cluster_name}" "${endpoint}"
    --with-secrets "${SECRETS_FILE}"
    --talos-version "${layout}"
    --kubernetes-version "${kubernetes_version}"
    --with-docs=false
    --with-examples=false
    --force
  )

  local count i name role disk schematic args
  count=$(yq -r '.nodes | length' "${CLUSTER_FILE}")
  for (( i = 0; i < count; i++ )); do
    name=$(yq -r ".nodes[${i}].name" "${CLUSTER_FILE}")
    role=$(yq -r ".nodes[${i}].role" "${CLUSTER_FILE}")
    disk=$(yq -r ".nodes[${i}].installDisk" "${CLUSTER_FILE}")
    schematic=$(yq -r ".nodes[${i}].schematic" "${CLUSTER_FILE}")

    [[ -f "${PATCH_DIR}/nodes/${name}.yaml" ]] || err "Missing patches/nodes/${name}.yaml"
    render_patch "${PATCH_DIR}/nodes/${name}.yaml" "${rendered}/${name}.yaml"

    args=(--config-patch "@${rendered}/all.yaml")
    if [[ "${role}" == "controlplane" ]]; then
      args+=(--config-patch "@${rendered}/controlplane.yaml")
    fi
    args+=(--config-patch "@${rendered}/${name}.yaml")

    talosctl gen config "${common[@]}" \
      --output-types "${role}" \
      --install-disk "${disk}" \
      --install-image "factory.talos.dev/installer/${schematic}:${talos_version}" \
      "${args[@]}" \
      -o "${OUTPUT_DIR}/${cluster_name}-${name}.yaml"
  done

  talosctl gen config "${common[@]}" --output-types talosconfig -o "${OUTPUT_DIR}/talosconfig"
  chmod 600 "${OUTPUT_DIR}"/*

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

  # Strip https:// prefix and :port suffix from the cluster endpoint
  # (e.g., https://beelink.catfish-mountain.ts.net:6443) to get just the hostname
  local endpoint
  endpoint=$(yq -r '.endpoint' "${CLUSTER_FILE}" | sed -e 's|https://||' -e 's|:[0-9]*$||')

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
