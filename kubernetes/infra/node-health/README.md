# node-health

External dead man's switch monitoring for cluster nodes via [healthchecks.io](https://healthchecks.io).

## Overview

Solves the "who watches the watchmen" problem: in-cluster monitoring (like SigNoz) can't detect when the entire cluster or individual nodes go down. This app sends periodic heartbeats to an external service, which alerts you when heartbeats stop.

## Components

### Self-Configuring DaemonSet
- Runs on every node (including control plane)
- On startup:
  1. Sends initial ping → auto-creates check in healthchecks.io
  2. Waits 5 seconds for check to appear in API
  3. Configures check period (2 min) and grace (5 min) via Management API
- Then continues pinging every 2 minutes
- Each pod manages its own check independently

## Setup

### 1. Create healthchecks.io Account

1. Sign up at https://healthchecks.io (free tier)
2. Create a project (e.g., "homelab")
3. Go to Project Settings
4. Copy the **Ping Key** (UUID format)

### 2. Store Keys in Bitwarden

Store two secrets in Bitwarden Secrets Manager:

**Management API Key:**
- Create API key in healthchecks.io Settings → API Keys
- Name: `healthchecks-api-key` (or any name)
- Value: Your healthchecks.io API key
- Copy the Bitwarden secret UUID

**Ping Key:**
- Name: `healthchecks-ping-key` (or any name)
- Value: Your healthchecks.io ping key
- Copy the Bitwarden secret UUID

### 3. Update values.yaml

```yaml
bitwarden-secret:
  enabled: true
  secrets:
    - name: healthchecks-api-key
      data:
        api-key: "<bitwarden-secret-uuid>"
    - name: healthchecks-ping-key
      data:
        ping-key: "<bitwarden-secret-uuid>"
```

### 4. Deploy

Commit and push - ArgoCD will sync automatically.

### 5. Configure Notifications

After first sync, checks will auto-create in healthchecks.io. Each check is already configured with:
- **Period**: 2 minutes (matches ping interval)
- **Grace**: 5 minutes (tolerates 2-3 missed pings)

**Total time before alert:** 7 minutes (2 min period + 5 min grace)

Configure email notifications:
1. Go to Project Settings → Notifications
2. Add your email
3. Test the integration

## How It Works

1. **DaemonSet pod starts** → Sends initial ping to healthchecks.io
2. **healthchecks.io** → Auto-creates check with node name (e.g., "rpi5", "beelink")
3. **Pod waits 5 seconds** → Gives check time to appear in API
4. **Pod configures check** → Sets period=2min, grace=5min via Management API
5. **Pod pings every 2 minutes** → Check stays "up"
6. **Node/cluster fails** → Pings stop → After 7 minutes, you get email alert

Each pod is self-contained and manages its own check lifecycle.

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `healthchecks.pingUrl` | Healthchecks.io ping endpoint | `https://hc-ping.com` |
| `healthchecks.interval` | Ping interval in seconds | `120` (2 min) |
| `healthchecks.gracePeriod` | Recommended grace in healthchecks.io | `300` (5 min) |
| `healthchecks.timeout` | Curl timeout in seconds | `10` |
| `image.repository` | Container image | `curlimages/curl` |
| `image.tag` | Image tag | `8.18.0` |

## Troubleshooting

### Pods not starting
```bash
kubectl get pods -n node-health
kubectl logs -n node-health -l app.kubernetes.io/name=node-health
```

### Checks not auto-creating
- Verify ping key secret exists: `kubectl get secret healthchecks-ping-key -n node-health`
- Check pod logs for 404 errors (wrong ping key)

### Checks not configured correctly
- Verify API key secret exists: `kubectl get secret healthchecks-api-key -n node-health`
- Check pod logs for configuration errors:
  ```bash
  kubectl logs -n node-health -l app.kubernetes.io/name=node-health | grep -A 10 "Configuring check"
  ```

### Update check configuration
If you change the interval or grace period, restart the pods:
```bash
kubectl rollout restart daemonset/node-health -n node-health
```
Each pod will reconfigure its check on startup with the new settings.

## Scaling

Adding new nodes is automatic:
1. Node joins cluster
2. DaemonSet schedules pod on new node
3. Pod starts → creates and configures its own check
4. Done! Check is properly configured within ~10 seconds

No manual intervention or ArgoCD sync required.

## Security

- **Read-only root filesystem**: Container runs with minimal write access
- **No root**: Runs as non-root user (curl_user)
- **Dropped capabilities**: All Linux capabilities removed
- **Secrets**: Stored in Bitwarden Secrets Manager, not in git
