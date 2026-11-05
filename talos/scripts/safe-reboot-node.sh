#!/usr/bin/env bash
set -euo pipefail

# Safe Talos reboot: never reboot while storage state is unknown or in use.
# Usage: ./safe-reboot-node.sh <node-name>

NODE_NAME="${1:-}"
if [[ $# -ne 1 || -z "$NODE_NAME" ]]; then
  echo "Usage: $0 <node-name>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_FILE="$SCRIPT_DIR/../cluster.yaml"
KUBE_CONTEXT=homelab
TALOS_CONTEXT=homelab
DETACH_TIMEOUT="${SAFE_REBOOT_DETACH_TIMEOUT:-180}"
RECOVERY_TIMEOUT="${SAFE_REBOOT_RECOVERY_TIMEOUT:-600}"

fail() {
  echo "Error: $*" >&2
  echo "If cordoned, the node remains cordoned for inspection." >&2
  exit 1
}

[[ "$DETACH_TIMEOUT" =~ ^[0-9]+$ && "$RECOVERY_TIMEOUT" =~ ^[0-9]+$ ]] || fail "Timeout values must be whole seconds"

# Read the target from this repository, and verify both clients point at its
# control plane before changing anything. All subsequent calls pin the context.
CLUSTER_JSON=$(yq -o=json '.' "$CLUSTER_FILE") || fail "Cannot read cluster.yaml"
TARGET=$(jq -ec --arg node "$NODE_NAME" '
  if (.endpoint | type) != "string" or (.nodes | type) != "array" then error("invalid cluster definition") else . end
  | . as $cluster
  | [.nodes[] | select(.name == $node)] as $matches
  | if ($matches | length) != 1 then error("node missing or duplicated") else
      {endpoint: $cluster.endpoint, name: $matches[0].name, lanIP: ($matches[0].lanIP // "")}
    end
  | if (.endpoint | test("^https://[^/]+:6443$")) and
       (.name | type == "string") and (.lanIP | type == "string")
    then . else error("invalid target") end
' <<<"$CLUSTER_JSON") || fail "Node '$NODE_NAME' is not a valid cluster.yaml target"
KUBE_SERVER=$(jq -r '.endpoint' <<<"$TARGET")
LAN_IP=$(jq -r '.lanIP' <<<"$TARGET")
TALOS_ENDPOINT="${KUBE_SERVER#https://}"
TALOS_ENDPOINT="${TALOS_ENDPOINT%:6443}"

KUBE_CONFIG=$(kubectl --context "$KUBE_CONTEXT" config view --minify -o json) || fail "Cannot read Kubernetes context '$KUBE_CONTEXT'"
jq -e --arg context "$KUBE_CONTEXT" --arg server "$KUBE_SERVER" '
  (.contexts | length) == 1 and .contexts[0].name == $context and
  (.clusters | length) == 1 and .clusters[0].cluster.server == $server
' <<<"$KUBE_CONFIG" >/dev/null || fail "Kubernetes context does not point at $KUBE_SERVER"
TALOS_CONFIG=$(talosctl --context "$TALOS_CONTEXT" config info -o json) || fail "Cannot read Talos context '$TALOS_CONTEXT'"
jq -e --arg context "$TALOS_CONTEXT" --arg endpoint "$TALOS_ENDPOINT" '
  .context == $context and (.endpoints | type) == "array" and
  (.endpoints | index($endpoint)) != null
' <<<"$TALOS_CONFIG" >/dev/null || fail "Talos context does not point at $TALOS_ENDPOINT"

kube() { kubectl --context "$KUBE_CONTEXT" "$@"; }
talos() { talosctl --context "$TALOS_CONTEXT" "$@"; }

NODE_JSON=$(kube get node "$NODE_NAME" -o json) || fail "Cannot query node '$NODE_NAME'"
jq -e --arg node "$NODE_NAME" '.metadata.name == $node and (.status.nodeInfo.bootID | type == "string" and length > 0)' <<<"$NODE_JSON" >/dev/null || fail "Node identity or boot ID is missing"
BOOT_ID=$(jq -r '.status.nodeInfo.bootID' <<<"$NODE_JSON")

echo "=== Safe Reboot Procedure for $NODE_NAME ==="
echo "Step 1/6: Cordoning node..."
kube cordon "$NODE_NAME" || fail "Cordon failed"

echo "Step 2/6: Draining node..."
kube drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --timeout=300s --grace-period=120 || fail "Drain failed"

echo "Step 3/6: Waiting for Longhorn volumes to detach..."
# A cleared spec.nodeID only requests detachment. status.state and
# status.currentNodeID report the observed result. Migration can leave a
# second engine on this node, so check that status field too.
ELAPSED=0
while :; do
  VOLUMES_JSON=$(kube get volumes.longhorn.io -n longhorn -o json) || fail "Longhorn volume query failed"
  BLOCKING_VOLUMES=$(jq -ec --arg node "$NODE_NAME" '
    if (.items | type) != "array" then error("missing volume list") else .items end
    | map(
        if (.metadata.name | type) != "string" or
           (.spec.nodeID | type) != "string" or
           (.status.state | type) != "string" or
           (.status.currentNodeID | type) != "string" or
           ((.status.currentMigrationNodeID // "") | type) != "string"
        then error("incomplete volume state") else . end
      )
    | map(select(.spec.nodeID == $node or .status.currentNodeID == $node or
                 .status.currentMigrationNodeID == $node))
    | map({name: .metadata.name, desired: .spec.nodeID,
           actual: .status.currentNodeID, migration: (.status.currentMigrationNodeID // ""),
           state: .status.state})
  ' <<<"$VOLUMES_JSON") || fail "Longhorn volume state is incomplete or invalid"
  if [[ $(jq 'length' <<<"$BLOCKING_VOLUMES") -eq 0 ]]; then
    echo "✓ No Longhorn volumes attached to or requested on $NODE_NAME"
    break
  fi
  echo "Waiting for Longhorn volumes: $BLOCKING_VOLUMES (${ELAPSED}s elapsed)"
  if (( ELAPSED >= DETACH_TIMEOUT )); then
    fail "Timed out waiting for Longhorn detachment"
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo "Step 4/6: Checking pods with PVCs on the node..."
PODS_JSON=$(kube get pods -A -o json) || fail "Pod query failed"
PODS_WITH_PVCS=$(jq -ec --arg node "$NODE_NAME" '
  if (.items | type) != "array" then error("missing pod list") else .items end
  | map(
      if (.metadata.name | type) != "string" or (.metadata.namespace | type) != "string" or
         (.spec | type) != "object" or ((.spec.volumes // []) | type) != "array"
      then error("incomplete pod state") else . end
    )
  | map(select(.spec.nodeName == $node and
               any((.spec.volumes // [])[]; has("persistentVolumeClaim"))))
  | map(.metadata.namespace + "/" + .metadata.name)
' <<<"$PODS_JSON") || fail "Pod storage state is incomplete or invalid"
if [[ $(jq 'length' <<<"$PODS_WITH_PVCS") -gt 0 ]]; then
  fail "PVC-using pods remain on $NODE_NAME: $PODS_WITH_PVCS"
fi
echo "✓ No PVC-using pods remain"

echo "Step 5/6: Rebooting node via talosctl..."
if [[ -n "$LAN_IP" ]]; then
  TALOS_TARGET=(-n "$LAN_IP" -e "$LAN_IP")
else
  TALOS_TARGET=(-n "${NODE_NAME}.catfish-mountain.ts.net" -e "$TALOS_ENDPOINT")
fi
talos "${TALOS_TARGET[@]}" reboot --wait=false || fail "Talos reboot command failed"

echo "Step 6/6: Waiting for a new boot ID and Ready condition..."
DEADLINE=$((SECONDS + RECOVERY_TIMEOUT))
until NEW_BOOT_ID=$(kube get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null) \
  && [[ -n "$NEW_BOOT_ID" && "$NEW_BOOT_ID" != "$BOOT_ID" ]]; do
  if (( SECONDS >= DEADLINE )); then
    fail "Node did not report a new boot ID within ${RECOVERY_TIMEOUT}s"
  fi
  sleep 10
done
REMAINING=$((DEADLINE - SECONDS))
if (( REMAINING <= 0 )); then
  fail "Node did not become Ready within ${RECOVERY_TIMEOUT}s"
fi
kube wait --for=condition=Ready "node/$NODE_NAME" --timeout="${REMAINING}s" || fail "Node rebooted but did not become Ready"

kube uncordon "$NODE_NAME" || fail "Node is Ready but uncordon failed"
echo "=== Reboot complete ==="
