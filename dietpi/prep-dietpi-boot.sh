#!/usr/bin/env bash
set -euo pipefail

# Prepares a freshly-flashed DietPi boot partition for k3s + Tailscale.
#
# Usage:
#   1. Flash a DietPi image onto an SD card or USB drive.
#   2. Insert/mount the boot partition of that media on your computer.
#      - On macOS: usually /Volumes/boot
#      - On Linux: usually /media/$USER/boot
#   3. Run this script, pointing it at the boot partition:
#
#         ./prep-dietpi-boot.sh /path/to/boot
#
#   This will:
#     - Append cgroup flags to cmdline.txt (if missing).
#     - Prompt for device hostname and post-install script URL,
#       and write them into dietpi.txt.
#     - Prompt for Tailscale/Kubernetes secrets and role (server/agent),
#       and write them into post-install.env on the boot partition.
#
#   After running, eject the media, insert it into your device,
#   and power on. DietPi will pick up the settings and execute
#   your custom post-install script.

# --- helpers ---------------------------------------------------------------

err() { echo "[error]: $*" >&2; exit 1; }
info() { echo "[info]: $*"; }

require_file() {
  local p="$1"
  [[ -f "$p" ]] || err "Missing required file: $p"
}

escape_sed_repl() {
  # Escape chars that are special in the sed replacement section
  # (ampersand and backslash)
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  printf '%s' "$s"
}

replace_or_add_kv() {
  # replace_or_add_kv <file> <KEY> <VALUE>
  local file="$1" key="$2" val="$3"
  local val_esc
  val_esc="$(escape_sed_repl "$val")"

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
    # Uncomment if needed and replace value
    sed -i.bak -E "s|^[[:space:]]*#?[[:space:]]*(${key})=.*|\1=${val_esc}|g" "$file"
  else
    printf "%s=%s\n" "$key" "$val" >> "$file"
  fi
}

append_cmdline_flag_if_missing() {
  # append_cmdline_flag_if_missing <file> "<flag>"
  local file="$1" flag="$2"
  # cmdline.txt is a single line; add a leading space before appending
  if ! grep -qE "(^| )${flag}( |$)" "$file"; then
    local contents
    contents="$(tr -d '\n' < "$file")"
    printf "%s %s\n" "$contents" "$flag" > "$file"
  fi
}

lower() { tr '[:upper:]' '[:lower:]'; }

# --- main ------------------------------------------------------------------

BOOT_MNT="${1:-}"
[[ -n "$BOOT_MNT" ]] || err "Usage: $0 /path/to/boot-partition"

CMDLINE_TXT="$BOOT_MNT/cmdline.txt"
DIETPI_TXT="$BOOT_MNT/dietpi.txt"
ENV_FILE="$BOOT_MNT/post-install.env"

require_file "$CMDLINE_TXT"
require_file "$DIETPI_TXT"

info "Updating kernel cgroup flags in cmdline.txt..."
append_cmdline_flag_if_missing "$CMDLINE_TXT" "cgroup_enable=cpuset"
append_cmdline_flag_if_missing "$CMDLINE_TXT" "cgroup_enable=memory"
append_cmdline_flag_if_missing "$CMDLINE_TXT" "cgroup_memory=1"

info "Collecting settings to write into dietpi.txt..."
read -rp "Device name (e.g., rpi5a): " DEVICE_NAME
[[ -n "${DEVICE_NAME:-}" ]] || err "Device name cannot be empty."

read -rp "URL to DietPi post-install script: " POST_INSTALL_URL
[[ -n "${POST_INSTALL_URL:-}" ]] || err "Post-install script URL cannot be empty."

# Write values to dietpi.txt
replace_or_add_kv "$DIETPI_TXT" "AUTO_SETUP_NET_HOSTNAME" "$DEVICE_NAME"
replace_or_add_kv "$DIETPI_TXT" "AUTO_SETUP_CUSTOM_SCRIPT_EXEC" "$POST_INSTALL_URL"

info "Collecting secrets and role for post-install.env..."
read -rp "Tailscale auth key: " TS_AUTH_KEY
[[ -n "${TS_AUTH_KEY:-}" ]] || err "Tailscale auth key cannot be empty."

# -s for silent password input; show prompt first
echo -n "K3s password: "
read -rs K3S_PASSWORD
echo
[[ -n "${K3S_PASSWORD:-}" ]] || err "K3s password cannot be empty."

# Ask role and (if agent) ask for server address
K3S_ROLE=""
K3S_SERVER_URL=""

while :; do
  read -rp "Is this node a k3s server or agent? [server/agent]: " ROLE_IN
  ROLE_IN="$(echo "${ROLE_IN:-}" | lower)"
  if [[ "$ROLE_IN" == "server" ]]; then
    K3S_ROLE="server"
    break
  elif [[ "$ROLE_IN" == "agent" ]]; then
    K3S_ROLE="agent"
    read -rp "Enter the k3s server Tailscale IP or URL (e.g., 100.x.x.x or https://...): " K3S_SERVER_URL
    [[ -n "${K3S_SERVER_URL:-}" ]] || err "Server address is required for agent role."
    break
  else
    echo "Please type 'server' or 'agent'."
  fi
done

info "Writing $ENV_FILE..."
cat > "$ENV_FILE" <<EOF
# Plaintext environment for post-install script.
# This file should be deleted by the post-install script.

TS_AUTH_KEY=${TS_AUTH_KEY}
K3S_ROLE=${K3S_ROLE}
K3S_PASSWORD=${K3S_PASSWORD}
K3S_SERVER_URL=${K3S_SERVER_URL}
EOF

chmod 600 "$ENV_FILE"

info "Done!"
echo "  - Updated: $CMDLINE_TXT"
echo "  - Updated: $DIETPI_TXT"
echo "  - Created: $ENV_FILE"
echo
echo "Next steps:"
echo "  • Insert SD card or USB drive into the Raspberry Pi and power it on."
echo "  • DietPi should apply hostname/custom script on first boot."
echo "  • Your post-install script will read the secrets from ${ENV_FILE##*/}."
