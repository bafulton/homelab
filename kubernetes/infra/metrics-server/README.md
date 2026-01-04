# Metrics Server

Cluster-wide resource metrics aggregator. Collects CPU and memory usage from kubelets.

## Why It's Needed

Required for:
- `kubectl top nodes` / `kubectl top pods`
- Horizontal Pod Autoscaler (HPA)
- Vertical Pod Autoscaler (VPA)
- Kubernetes Dashboard resource graphs

## Talos Configuration

Uses `--kubelet-insecure-tls` because kubelet certificates don't include Tailscale IP SANs. When metrics-server connects to kubelets via Tailscale IPs, standard TLS verification would fail.
