set -u

# An otherwise unused routing protocol marks rules this controller owns. Match
# priority and table as well, so another protocol 242 user is left alone.
RULE_PROTOCOL=242
log() { echo "subnet-route-steering: $*" >&2; }

owned_rules() {
  rules=$(ip -4 -j rule list) || { log "failed to list IPv4 rules"; return 1; }
  printf '%s\n' "$rules" | jq -r --argjson priority "$PRIORITY" --arg protocol "$RULE_PROTOCOL" '
    .[] | select(.priority == $priority and .protocol == $protocol and
                 .table == "main" and .src == "all" and .dst != null) |
    .dst + "/" + (.dstlen | tostring)
  ' || { log "failed to parse IPv4 rules"; return 1; }
}

contains() {
  printf '%s\n' "$1" | grep -Fxq -- "$2"
}

reconcile() {
  if [ "$ENABLED" = "true" ]; then
    # Finish discovery and validation before changing any host rule. Missing
    # CIDRs are treated as incomplete discovery rather than removed peers.
    if ! nodes=$(kubectl get nodes -l "$SELECTOR" -o json 2>&1); then
      log "node discovery failed: $nodes"
      return 1
    fi
    if ! desired=$(printf '%s\n' "$nodes" | jq -er --arg node "$NODE_NAME" --arg lan "$LANCIDR" '
      if all(.items[]; (.spec.podCIDR // "") != "") then
        ([$lan] + [.items[] | select(.metadata.name != $node) | .spec.podCIDR]) | unique | .[]
      else error("local node has no podCIDR") end
    '); then
      log "invalid or incomplete node discovery; preserving existing rules"
      return 1
    fi
  else
    desired=''
  fi

  current=$(owned_rules) || return 1
  if [ -n "$desired" ]; then
    while IFS= read -r cidr; do
      if ! contains "$current" "$cidr"; then
        if ! ip -4 rule add to "$cidr" table main priority "$PRIORITY" protocol "$RULE_PROTOCOL"; then
          log "failed to add rule for $cidr; preserving existing rules"
          return 1
        fi
        log "added rule for $cidr"
      fi
    done <<EOF
$desired
EOF
  fi

  # Refresh after additions. Delete by the full owned rule identity, never by
  # priority alone; unrelated rules at this priority must survive.
  current=$(owned_rules) || return 1
  if [ -n "$current" ]; then
    while IFS= read -r cidr; do
      if ! contains "$desired" "$cidr"; then
        if ! ip -4 rule del to "$cidr" table main priority "$PRIORITY" protocol "$RULE_PROTOCOL"; then
          log "failed to delete obsolete rule for $cidr"
          return 1
        fi
        log "deleted obsolete rule for $cidr"
      fi
    done <<EOF
$current
EOF
  fi
}

log "enabled=$ENABLED node=$NODE_NAME selector='$SELECTOR' priority=$PRIORITY interval=${INTERVAL}s protocol=$RULE_PROTOCOL"
while true; do
  if ! reconcile; then
    log "reconciliation failed; retrying in ${INTERVAL}s"
  fi
  sleep "$INTERVAL"
done
