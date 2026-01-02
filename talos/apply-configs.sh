#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Talos Config Applier
# ============================================================================
#
# Scans for Talos nodes on the local network, displays hardware info
# (MAC addresses, disks) to help identify them, and applies configs.
#
# Usage: ./apply-configs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/clusterconfig"
CLUSTER_NAME="homelab"

log()  { printf "\n==> %s\n" "$*"; }
err()  { printf "\n[error] %s\n" "$*" >&2; exit 1; }

check_dependencies() {
  if ! command -v talosctl >/dev/null 2>&1; then
    err "talosctl is required but not installed. See: https://www.talos.dev/latest/introduction/getting-started/#talosctl"
  fi
}

check_generated_configs() {
  if [[ ! -d "${GENERATED_DIR}" ]]; then
    err "Generated configs not found in ${GENERATED_DIR}. Run ./generate-configs.sh first."
  fi

  # Check for at least one config file
  local config_count
  config_count=$(find "${GENERATED_DIR}" -name "${CLUSTER_NAME}-*.yaml" 2>/dev/null | wc -l)
  if [[ "${config_count}" -eq 0 ]]; then
    err "No config files found in ${GENERATED_DIR}. Run ./generate-configs.sh first."
  fi
}

discover_configs() {
  # Talhelper generates configs named: <cluster>-<hostname>.yaml
  # e.g., homelab-beelink.yaml, homelab-rpi3.yaml
  CONFIG_NAMES=()
  CONFIG_FILES=()

  for f in "${GENERATED_DIR}"/${CLUSTER_NAME}-*.yaml; do
    if [[ -f "$f" ]]; then
      # Extract hostname from filename (e.g., homelab-beelink.yaml -> beelink)
      local hostname
      hostname=$(basename "$f" .yaml | sed "s/^${CLUSTER_NAME}-//")
      CONFIG_NAMES+=("$hostname")
      CONFIG_FILES+=("$f")
    fi
  done

  if [[ ${#CONFIG_FILES[@]} -eq 0 ]]; then
    err "No config files found matching ${CLUSTER_NAME}-*.yaml in ${GENERATED_DIR}"
  fi

  log "Found configs for: ${CONFIG_NAMES[*]}"
}

detect_subnet() {
  log "Detecting local subnet"

  # Try to get the default route interface and its subnet
  local subnet=""

  if command -v ip >/dev/null 2>&1; then
    # Linux
    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -n "$iface" ]]; then
      subnet=$(ip -o -f inet addr show "$iface" | awk '{print $4}' | head -1)
    fi
  elif command -v route >/dev/null 2>&1; then
    # macOS
    local iface
    iface=$(route -n get default 2>/dev/null | grep interface | awk '{print $2}')
    if [[ -n "$iface" ]]; then
      local ip_addr
      ip_addr=$(ifconfig "$iface" | grep 'inet ' | awk '{print $2}')
      if [[ -n "$ip_addr" ]]; then
        # Assume /24 subnet
        subnet="${ip_addr%.*}.0/24"
      fi
    fi
  fi

  if [[ -z "$subnet" ]]; then
    printf "Could not auto-detect subnet.\n"
    printf "Enter subnet to scan (e.g., 192.168.1.0/24): "
    read -r subnet
  else
    printf "Detected subnet: %s\n" "$subnet"
    printf "Use this subnet? [Y/n] "
    read -r confirm
    if [[ "${confirm}" =~ ^[Nn]$ ]]; then
      printf "Enter subnet to scan (e.g., 192.168.1.0/24): "
      read -r subnet
    fi
  fi

  SUBNET="$subnet"
}

scan_for_nodes() {
  log "Scanning for Talos nodes on ${SUBNET}"
  printf "This may take a minute...\n\n"

  # Extract base IP from subnet (e.g., 192.168.1.0/24 -> 192.168.1)
  local base_ip="${SUBNET%.*}"

  FOUND_NODES=()
  FOUND_MACS=()
  FOUND_DISKS=()

  # Determine timeout command (if available)
  local timeout_cmd=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout 3"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout 3"
  fi

  # Scan common DHCP range (adjust if needed)
  for i in {1..254}; do
    local ip="${base_ip}.${i}"

    # Show progress (use fixed width to avoid visual artifacts)
    printf "\r  Scanning %-15s                    " "$ip"

    # Quick check if host is up (timeout 1 second)
    if ! ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      continue
    fi

    printf "\r  Scanning %-15s [up, checking for Talos]" "$ip"

    # Try to get Talos info (with 3 second timeout if available)
    local disks_output
    if disks_output=$($timeout_cmd talosctl get disks -n "$ip" -i 2>/dev/null); then
      # It's a Talos node! Get more info
      local mac="unknown"
      local disk_summary=""

      # Get MAC address from links
      local links_output
      if links_output=$($timeout_cmd talosctl get links -n "$ip" -i -o yaml 2>/dev/null); then
        # Extract MAC of first physical interface (usually eth0 or enp*)
        mac=$(echo "$links_output" | grep -A5 'kind: ethernet' | grep 'hardwareAddr:' | head -1 | awk '{print $2}' || true)
        if [[ -z "$mac" ]]; then
          mac=$(echo "$links_output" | grep 'hardwareAddr:' | head -1 | awk '{print $2}' || true)
        fi
      fi

      # Summarize disk info (get disks output: NODE NAMESPACE TYPE ID VERSION SIZE ...)
      # When NODE is blank, columns shift: $3=ID, $5=size number, $6=size unit
      disk_summary=$(echo "$disks_output" | tail -n +2 | grep -v '^[[:space:]]*$' | awk '{printf "%s (%s %s) ", $3, $5, $6}' || true)
      disk_summary="${disk_summary:0:60}"

      FOUND_NODES+=("$ip")
      FOUND_MACS+=("${mac:-unknown}")
      FOUND_DISKS+=("${disk_summary:-unknown}")

      printf "  Found: %s | MAC: %s | Disks: %s\n" "$ip" "${mac:-unknown}" "${disk_summary:-unknown}"
    fi
  done

  # Clear the progress line
  printf "\r                                        \r"

  if [[ ${#FOUND_NODES[@]} -eq 0 ]]; then
    err "No Talos nodes found on ${SUBNET}. Make sure nodes are booted and on the network."
  fi

  printf "Found %d Talos node(s)\n" "${#FOUND_NODES[@]}"
}

match_nodes_to_configs() {
  log "Match nodes to configs"

  NODE_ASSIGNMENTS=()

  for config_name in "${CONFIG_NAMES[@]}"; do
    printf "\nWhich node is '%s'?\n" "$config_name"

    # Show available nodes
    local available=()
    for i in "${!FOUND_NODES[@]}"; do
      # Check if already assigned
      local assigned=false
      for a in "${NODE_ASSIGNMENTS[@]:-}"; do
        if [[ "$a" == "$i" ]]; then
          assigned=true
          break
        fi
      done

      if [[ "$assigned" == "false" ]]; then
        available+=("$i")
        printf "  [%d] %s | MAC: %s | Disks: %s\n" "$((i + 1))" "${FOUND_NODES[$i]}" "${FOUND_MACS[$i]}" "${FOUND_DISKS[$i]}"
      fi
    done

    if [[ ${#available[@]} -eq 1 ]]; then
      # Auto-select if only one left
      printf "  -> Auto-selecting only remaining node\n"
      NODE_ASSIGNMENTS+=("${available[0]}")
    else
      printf "Enter number: "
      read -r selection
      local idx=$((selection - 1))

      if [[ $idx -lt 0 || $idx -ge ${#FOUND_NODES[@]} ]]; then
        err "Invalid selection"
      fi

      NODE_ASSIGNMENTS+=("$idx")
    fi
  done
}

confirm_apply() {
  log "Configuration Summary"

  for i in "${!CONFIG_NAMES[@]}"; do
    local node_idx="${NODE_ASSIGNMENTS[$i]}"
    printf "  %s -> %s (MAC: %s)\n" "${CONFIG_NAMES[$i]}" "${FOUND_NODES[$node_idx]}" "${FOUND_MACS[$node_idx]}"
  done

  printf "\nApply configs? [Y/n] "
  read -r confirm
  if [[ "${confirm}" =~ ^[Nn]$ ]]; then
    err "Aborted by user"
  fi
}

apply_configs() {
  for i in "${!CONFIG_NAMES[@]}"; do
    local node_idx="${NODE_ASSIGNMENTS[$i]}"
    local ip="${FOUND_NODES[$node_idx]}"
    local config="${CONFIG_FILES[$i]}"

    log "Applying config for ${CONFIG_NAMES[$i]} to ${ip}"
    talosctl apply-config -i \
      -n "$ip" \
      -f "$config"
  done
}

print_summary() {
  log "Configs applied!"

  printf "\nNodes will now reboot and Tailscale will come up.\n"
  printf "Wait 2-3 minutes, then verify nodes are reachable:\n"
  printf "  talosctl health\n"
  printf "\nOnce healthy, run:\n"
  printf "  ./bootstrap.sh\n"
}

main() {
  check_dependencies
  check_generated_configs
  discover_configs
  detect_subnet
  scan_for_nodes
  match_nodes_to_configs
  confirm_apply
  apply_configs
  print_summary
}

main "$@"
