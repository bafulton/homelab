# Metrics Server

Cluster-wide resource metrics aggregator. Collects CPU and memory usage from kubelets.

## Why It's Needed

Required for:
- `kubectl top nodes` / `kubectl top pods`
- Horizontal Pod Autoscaler (HPA)
- Vertical Pod Autoscaler (VPA)
- Kubernetes Dashboard resource graphs
