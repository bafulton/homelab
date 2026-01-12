# Kube State Metrics

Generates metrics about the state of Kubernetes objects.

## Why It's Needed

Complements signoz-k8s-infra's cluster metrics with detailed object state:
- Deployment replica counts and availability
- Pod phase and restart counts
- PVC status and capacity
- Node conditions and capacity
- Job/CronJob status

## Metrics Examples

- `kube_deployment_status_replicas_available`
- `kube_pod_container_status_restarts_total`
- `kube_node_status_condition`
- `kube_persistentvolumeclaim_status_phase`

## Integration

Metrics are auto-discovered by signoz-k8s-infra via prometheus scrape config.
