#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Talos Config Generator
# ============================================================================
#
# Generates Talos machine configs for a homelab Kubernetes cluster.
# Prompts for all configuration interactively to avoid storing secrets
# in bash history and to allow customization per deployment.
#
# Usage: ./generate-configs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="${SCRIPT_DIR}/patches"
OUTPUT_DIR="${SCRIPT_DIR}/generated"

CLUSTER_NAME="homelab"

log()  { printf "\n==> %s\n" "$*"; }
err()  { printf "\n[error] %s\n" "$*" >&2; exit 1; }

check_dependencies() {
  local missing=()
  command -v talosctl >/dev/null 2>&1 || missing+=("talosctl")
  command -v envsubst >/dev/null 2>&1 || missing+=("envsubst (gettext)")

  if (( ${#missing[@]} > 0 )); then
    err "Missing required tools: ${missing[*]}"
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
  log "Secrets (input is hidden)"

  printf "Tailscale Auth Key: "
  read -rs TS_AUTHKEY
  printf "\n"

  if [[ -z "${TS_AUTHKEY}" ]]; then
    err "Tailscale auth key is required"
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
  if [[ "${confirm,,}" == "n" ]]; then
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

  # Generate control plane config
  talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
    --output-dir "${OUTPUT_DIR}" \
    --config-patch-control-plane "@${OUTPUT_DIR}/controlplane-patch.yaml" \
    --force

  # Generate worker configs (one per node)
  for hostname in "${WORKER_HOSTNAMES[@]}"; do
    log "Generating worker config for ${hostname}"

    talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
      --output-dir "${OUTPUT_DIR}" \
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

print_summary() {
  log "Config generation complete!"

  printf "\nGenerated files:\n"
  printf "  %s/controlplane.yaml  (%s)\n" "${OUTPUT_DIR}" "${CONTROLPLANE_HOSTNAME}"
  for hostname in "${WORKER_HOSTNAMES[@]}"; do
    printf "  %s/worker-%s.yaml\n" "${OUTPUT_DIR}" "${hostname}"
  done
  printf "  %s/talosconfig  (talosctl client config)\n" "${OUTPUT_DIR}"

  printf "\nNext steps:\n"
  printf "  1. Flash Talos images to your devices\n"
  printf "  2. Boot nodes and find their LAN IPs\n"
  printf "  3. Apply configs:\n"
  printf "       talosctl apply-config --insecure --nodes <LAN-IP> --file %s/controlplane.yaml\n" "${OUTPUT_DIR}"
  for hostname in "${WORKER_HOSTNAMES[@]}"; do
    printf "       talosctl apply-config --insecure --nodes <LAN-IP> --file %s/worker-%s.yaml\n" "${OUTPUT_DIR}" "${hostname}"
  done
  printf "  4. Configure talosctl:\n"
  printf "       cp %s/talosconfig ~/.talos/config\n" "${OUTPUT_DIR}"
  printf "       talosctl config endpoint %s.%s.ts.net\n" "${CONTROLPLANE_HOSTNAME}" "${TAILNET_NAME}"
  printf "       talosctl config node %s.%s.ts.net\n" "${CONTROLPLANE_HOSTNAME}" "${TAILNET_NAME}"
  printf "  5. Bootstrap the cluster:\n"
  printf "       talosctl bootstrap\n"
  printf "  6. Get kubeconfig:\n"
  printf "       talosctl kubeconfig\n"
}

main() {
  check_dependencies
  prompt_config
  prompt_secrets
  confirm_config
  generate_patches
  generate_talos_configs
  cleanup_patches
  print_summary
}

main "$@"
