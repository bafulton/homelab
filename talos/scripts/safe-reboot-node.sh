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
kubectl drain "$NODE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=300s \
  --grace-period=120
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
echo "Step 5/6: Rebooting node via talosctl..."
talosctl -n "${NODE_NAME}.catfish-mountain.ts.net" reboot
echo "✓ Reboot command sent"
echo ""

# Step 6: Wait for node to come back
echo "Step 6/6: Waiting for node to become Ready..."
echo "This typically takes 2-3 minutes..."
if kubectl wait --for=condition=Ready "node/$NODE_NAME" --timeout=600s; then
  echo "✓ Node is Ready"
else
  echo "⚠ Warning: Node did not become Ready within timeout"
  echo "Check node status manually: kubectl get node $NODE_NAME"
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
