#!/usr/bin/env bash
# Quick health check for the ESP32 BLE gateway (ble-gateway).
# Observes it purely over MQTT via the in-cluster Mosquitto broker — no web UI,
# no direct device access needed. Requires kubectl access to the cluster.
#
# Usage: ./gateway-status.sh [seconds]   (default 45s of BLE listening)

set -euo pipefail

NS="mosquitto"
BASE="home/ble-gateway"
LISTEN="${1:-45}"

POD="$(kubectl get pods -n "$NS" -o jsonpath='{.items[0].metadata.name}')"
if [ -z "$POD" ]; then
  echo "ERROR: no Mosquitto pod found in namespace '$NS'." >&2
  exit 1
fi
echo "Using Mosquitto pod: $POD"

echo
echo "=== Last Will / connectivity (retained — may be stale after a crash) ==="
kubectl exec -n "$NS" "$POD" -- \
  timeout 4 mosquitto_sub -h localhost -p 1883 -t "$BASE/LWT" -C 1 || echo "(no retained LWT)"

echo
echo "=== System status (waiting up to 75s for the next SYStoMQTT publish) ==="
echo "    look for: increasing uptime, \"mqtt\":true, env=esp32-m5atom-lite, sane rssi"
kubectl exec -n "$NS" "$POD" -- \
  timeout 75 mosquitto_sub -h localhost -p 1883 -t "$BASE/SYStoMQTT" -C 1 \
  || echo "(no SYS publish — SYS interval may be long; not necessarily unhealthy)"

echo
echo "=== Live BLE traffic (${LISTEN}s) — a healthy gateway shows a steady stream ==="
kubectl exec -n "$NS" "$POD" -- \
  timeout "$LISTEN" mosquitto_sub -h localhost -p 1883 -t "$BASE/BTtoMQTT/#" -v \
  | grep -vE '/config$' | head -40 || true

echo
echo "--- done ---"
echo "Healthy: SYS shows a git-SHA version with increasing uptime, and BTtoMQTT carries"
echo "decoded sensor lines (tempc/hum/pm25/co2). Allow a scan cycle (~55s) for a given sensor."
