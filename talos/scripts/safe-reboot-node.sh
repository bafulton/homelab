#!/bin/bash
set -e

# Safe Node Reboot Script for Talos + Longhorn
#
# This script performs a safe reboot of a Talos node that has Longhorn volumes.
# It ensures all volumes are properly detached before rebooting to prevent
# filesystem corruption from unsafe shutdowns.
#
# Usage: ./safe-reboot-node.sh <node-name>
# Example: ./safe-reboot-node.sh beelink

NODE_NAME="${1}"

if [ -z "$NODE_NAME" ]; then
  echo "Error: Node name required"
  echo "Usage: $0 <node-name>"
  echo "Example: $0 beelink"
  exit 1
fi

# Check if node exists
if ! kubectl get node "$NODE_NAME" &>/dev/null; then
  echo "Error: Node '$NODE_NAME' not found"
  exit 1
fi

echo "=== Safe Reboot Procedure for $NODE_NAME ==="
echo ""

# Step 1: Cordon the node
echo "Step 1/6: Cordoning node (preventing new pod scheduling)..."
kubectl cordon "$NODE_NAME"
echo "✓ Node cordoned"
echo ""

# Step 2: Drain the node
echo "Step 2/6: Draining node (evicting pods gracefully)..."
echo "This may take a few minutes..."
if ! kubectl drain "$NODE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=300s \
  --grace-period=120; then
  echo "✗ Drain failed; the node is still cordoned. A pod that won't evict is"
  echo "  usually a PDB (kubectl get pdb -A). Fix it and re-run, or undo with:"
  echo "  kubectl uncordon $NODE_NAME"
  exit 1
fi
echo "✓ Node drained"
echo ""

# Step 3: Wait for Longhorn volumes to detach
echo "Step 3/6: Waiting for Longhorn volumes to detach..."
MAX_WAIT=180  # 3 minutes
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  ATTACHED_VOLUMES=$(kubectl get volumes.longhorn.io -n longhorn -o json | \
    jq -r ".items[] | select(.spec.nodeID == \"$NODE_NAME\") | .metadata.name" | wc -l)

  if [ "$ATTACHED_VOLUMES" -eq 0 ]; then
    echo "✓ All Longhorn volumes detached"
    break
  fi

  echo "  Waiting for $ATTACHED_VOLUMES volume(s) to detach... (${ELAPSED}s elapsed)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo "⚠ Warning: Timeout waiting for volumes to detach"
  echo "The following volumes are still attached:"
  kubectl get volumes.longhorn.io -n longhorn -o json | \
    jq -r ".items[] | select(.spec.nodeID == \"$NODE_NAME\") | \"  - \(.metadata.name) (state: \(.status.state))\""
  echo ""
  read -p "Continue with reboot anyway? (yes/no): " CONTINUE
  if [ "$CONTINUE" != "yes" ]; then
    echo "Aborting reboot. Uncordoning node..."
    kubectl uncordon "$NODE_NAME"
    exit 1
  fi
fi
echo ""

# Step 4: Verify no pods using volumes
echo "Step 4/6: Verifying no pods are using volumes on this node..."
PODS_WITH_VOLUMES=$(kubectl get pods -A -o json | \
  jq -r ".items[] | select(.spec.nodeName == \"$NODE_NAME\") | select(.spec.volumes[]?.persistentVolumeClaim) | \"\(.metadata.namespace)/\(.metadata.name)\"" | wc -l)

if [ "$PODS_WITH_VOLUMES" -gt 0 ]; then
  echo "⚠ Warning: Found $PODS_WITH_VOLUMES pod(s) with PVCs still on node:"
  kubectl get pods -A -o json | \
    jq -r ".items[] | select(.spec.nodeName == \"$NODE_NAME\") | select(.spec.volumes[]?.persistentVolumeClaim) | \"  - \(.metadata.namespace)/\(.metadata.name)\""
else
  echo "✓ No pods with volumes remaining on node"
fi
echo ""

# Step 5: Reboot the node
# Over the LAN IP from cluster.yaml where the node has one, so Tailscale
# restarting mid-reboot can't cut the connection; remote nodes go via Tailscale.
echo "Step 5/6: Rebooting node via talosctl..."
CLUSTER_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cluster.yaml"
LAN_IP=$(yq -r ".nodes[] | select(.name == \"$NODE_NAME\") | .lanIP // \"\"" "$CLUSTER_FILE")
if [ -n "$LAN_IP" ]; then
  TALOS_TARGET=(-n "$LAN_IP" -e "$LAN_IP")
else
  TALOS_TARGET=(-n "${NODE_NAME}.catfish-mountain.ts.net")
fi
BOOT_ID=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.bootID}')
talosctl "${TALOS_TARGET[@]}" reboot --wait=false
echo "✓ Reboot command sent"
echo ""

# Step 6: Wait for node to come back
# The node still reports Ready until its kubelet stops, so wait for a new boot
# ID first; waiting on Ready alone would return before the reboot happened.
echo "Step 6/6: Waiting for node to reboot and become Ready..."
echo "This typically takes 2-3 minutes..."
DEADLINE=$((SECONDS + 600))
until [ "$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null)" != "$BOOT_ID" ]; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "⚠ Warning: Node did not reboot within 10 minutes; leaving it cordoned"
    echo "Check node status manually: kubectl get node $NODE_NAME"
    exit 1
  fi
  sleep 10
done
if kubectl wait --for=condition=Ready "node/$NODE_NAME" --timeout=$((DEADLINE - SECONDS))s; then
  echo "✓ Node rebooted and is Ready"
else
  echo "⚠ Warning: Node rebooted but did not become Ready; leaving it cordoned"
  echo "Check node status manually: kubectl get node $NODE_NAME"
  exit 1
fi
echo ""

# Uncordon the node
echo "Uncordoning node (allowing pod scheduling)..."
kubectl uncordon "$NODE_NAME"
echo "✓ Node uncordoned"
echo ""

echo "=== Reboot complete ==="
echo ""
echo "Post-reboot checklist:"
echo "  - Check node status: kubectl get node $NODE_NAME"
echo "  - Check Longhorn volumes: kubectl get volumes.longhorn.io -n longhorn"
echo "  - Check pods: kubectl get pods -A -o wide | grep $NODE_NAME"
