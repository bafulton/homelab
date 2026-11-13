#!/usr/bin/env bash
# Pushes the rendered Traefik config and the game-port firewall rules to the
# running edge VM, from this module's state.
#
# cloud-init only runs on first boot and the instance ignores user_data, so
# `tofu apply` alone changes the security list but not the VM. Run this after
# every apply that changes var.games (README.md, "Game servers"):
#
#   source ./env.sh && tofu apply && ./push-config.sh
#
# It keeps a timestamped copy of /etc/traefik before writing, and restarts
# Traefik only when traefik.yml changed (new entrypoints need a restart;
# dynamic.yml is watched). A restart drops connections in flight, Jellyfin
# streams included, for a second or two.
set -euo pipefail
cd "$(dirname "$0")"

host=${1:-edge-forwarder}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

tofu output -raw traefik_static >"$scratch/traefik.yml"
tofu output -raw traefik_dynamic >"$scratch/dynamic.yml"
rules=$(tofu output -json game_firewall_rules | jq -r '.[]')

remote() { ssh "ubuntu@$host" "$@"; }

backup="/etc/traefik.bak.$(date +%Y%m%d%H%M%S)"
remote "sudo cp -a /etc/traefik $backup"
echo "backed up /etc/traefik to $host:$backup"

restart=false
if ! remote 'sudo cat /etc/traefik/traefik.yml' | cmp -s - "$scratch/traefik.yml"; then
  restart=true
fi
for file in traefik.yml dynamic.yml; do
  remote "sudo tee /etc/traefik/$file >/dev/null" <"$scratch/$file"
done

# Replace exactly the rules this module owns: drop every edge-game rule, then
# add one per current game port. The forwarder's own ports are not touched.
remote "sudo iptables -S INPUT | grep -- '--comment edge-game' | sed 's/^-A /-D /' | xargs -r -L1 sudo iptables" || true
while read -r protocol port; do
  [ -n "$protocol" ] || continue
  remote "sudo iptables -I INPUT 1 -p $protocol --dport $port -m comment --comment edge-game -j ACCEPT"
done <<<"$rules"
remote 'sudo netfilter-persistent save >/dev/null'

if $restart; then
  remote 'sudo systemctl restart traefik'
  echo "traefik.yml changed: restarted Traefik"
fi
remote 'systemctl is-active traefik'
