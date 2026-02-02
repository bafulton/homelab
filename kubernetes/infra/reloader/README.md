# reloader

Stakater Reloader - automatically restarts workloads when their ConfigMaps or Secrets change.

## Overview

Kubernetes doesn't automatically restart pods when their ConfigMaps or Secrets are updated. Reloader watches for changes and triggers rolling restarts when configuration changes are detected.

**Without Reloader:**
1. Update ConfigMap/Secret
2. Manually restart deployment: `kubectl rollout restart deployment/myapp`

**With Reloader:**
1. Update ConfigMap/Secret
2. Pods automatically restart and pick up new config

## Configuration

This deployment uses **opt-in mode** (`autoReloadAll: false`), which means workloads must explicitly enable reloading via annotations.

### Enabling Reloader for a Workload

Add annotations to your Deployment/StatefulSet/DaemonSet:

**Watch specific ConfigMaps:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    reloader.stakater.com/search: "true"
spec:
  template:
    metadata:
      annotations:
        configmap.reloader.stakater.com/reload: "my-config,another-config"
```

**Watch specific Secrets:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    reloader.stakater.com/search: "true"
spec:
  template:
    metadata:
      annotations:
        secret.reloader.stakater.com/reload: "my-secret"
```

**Watch all mounted ConfigMaps and Secrets (automatic):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

### Why Opt-In?

`autoReloadAll: false` prevents unexpected restarts. Each workload explicitly declares whether it wants automatic reloading, giving you:
- **Control**: Only reload when needed
- **Predictability**: No surprise restarts during config updates
- **Flexibility**: Different restart strategies per workload

## When to Use Reloader

**Good use cases:**
- Apps with frequently changing configuration
- Feature flags or A/B testing configs
- External service credentials that rotate
- Environment-specific settings

**When NOT to use:**
- Helm chart updates (ArgoCD already handles this)
- Certificate rotation (most apps auto-reload certs)
- Static configuration that rarely changes

## Global Configuration

| Setting | Value | Description |
|---------|-------|-------------|
| `watchGlobally` | `true` | Watches resources in all namespaces |
| `autoReloadAll` | `false` | Requires opt-in via annotations |
| `logFormat` | `json` | Structured logging for observability |

## Monitoring

View Reloader logs:
```bash
kubectl logs -n reloader -l app.kubernetes.io/name=reloader -f
```

Logs show:
- Resources being watched
- Detected changes
- Triggered restarts

## How It Works

1. Reloader watches all ConfigMaps and Secrets in the cluster
2. When a change is detected, it checks if any Deployments/StatefulSets/DaemonSets have reloader annotations
3. For matching workloads, it updates a `reloader.stakater.com/last-reloaded-from` annotation
4. Kubernetes detects the annotation change and triggers a rolling restart
5. Pods restart and mount the updated ConfigMap/Secret

## Upstream Documentation

Full documentation: https://github.com/stakater/Reloader
