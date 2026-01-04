# Claude Context for Homelab

This document provides context for Claude Code sessions working on this repository.

## Git Workflow

Commit directly to main for routine changes. Use PRs for larger changes that benefit from review.

When using PRs, delete the local branch after merging:
```bash
gh pr merge <number> --merge && git checkout main && git pull && git branch -d <branch-name>
```

## Project Overview

GitOps-driven Kubernetes homelab running on Talos Linux with Tailscale networking.

**Key Technologies:**
- **Talos Linux** - Immutable, API-driven Kubernetes OS
- **Tailscale** - All nodes communicate over a private mesh network (no LAN exposure)
- **ArgoCD** - GitOps controller that syncs cluster state from this repo
- **Talhelper** - Declarative Talos configuration generator

## Cluster Architecture

| Node | Role | Architecture | Hostname |
|------|------|--------------|----------|
| Beelink Mini PC | Control Plane + Worker | amd64 | beelink |
| Raspberry Pi 3 | Worker | arm64 | rpi3 |
| Raspberry Pi 5 | Worker | arm64 | rpi5 |

- Control plane runs workloads (no taint, single-node control plane)
- All inter-node communication goes through Tailscale
- Tailnet: `catfish-mountain.ts.net`
- Kubernetes API: `https://beelink.catfish-mountain.ts.net:6443`

## Repository Structure

```
homelab/
├── talos/                    # Talos Linux configuration
│   ├── talconfig.yaml        # Declarative cluster config (source of truth)
│   ├── talsecret.yaml        # Cluster PKI secrets (gitignored)
│   ├── clusterconfig/        # Generated machine configs (gitignored)
│   ├── .env                  # TS_AUTHKEY (gitignored)
│   ├── generate-configs.sh   # Runs talhelper genconfig
│   ├── apply-configs.sh      # Applies configs to nodes
│   └── bootstrap.sh          # Bootstraps cluster + ArgoCD
│
├── kubernetes/               # GitOps manifests (managed by ArgoCD)
│   ├── applications.yaml     # Root app-of-apps (applied during bootstrap)
│   ├── appsets/              # ApplicationSets that generate ArgoCD apps
│   │   ├── infra.yaml        # Generates apps for infra/
│   │   └── apps.yaml         # Generates apps for apps/
│   ├── infra/                # Infrastructure Helm charts
│   │   ├── argocd/
│   │   ├── cert-manager/
│   │   ├── external-secrets/
│   │   ├── kubernetes-dashboard/
│   │   ├── longhorn/
│   │   ├── metallb/
│   │   ├── metrics-server/
│   │   ├── tailscale-operator/
│   │   ├── traefik/
│   │   └── tuppr/
│   └── apps/                 # User applications (none yet)
```

## GitOps Pattern

Each app in `infra/` or `apps/` is a wrapper Helm chart:
- `Chart.yaml` - Declares upstream chart as dependency
- `values.yaml` - Configuration values (also read by ApplicationSet for metadata)
- `templates/` - Additional resources (e.g., Tailscale Ingress, Secrets)

The ApplicationSets scan for `values.yaml` files and generate ArgoCD Applications automatically.

### Adding a New App

1. Create directory: `kubernetes/infra/my-app/` or `kubernetes/apps/my-app/`
2. Add `Chart.yaml` with upstream dependency
3. Add `values.yaml` with configuration
4. Commit and push - ArgoCD auto-syncs

### Values.yaml Conventions

```yaml
# Optional: Override namespace (defaults to directory name)
namespace: custom-namespace

# Optional: Enable server-side apply for CRD-heavy charts
serverSideApply: true

# Tailscale exposure (if using tailscale-ingress template)
tailscale:
  enabled: true
  hostname: my-app  # becomes my-app.catfish-mountain.ts.net

# Upstream chart values nested under chart name
my-upstream-chart:
  key: value
```

## Important Patterns

### Tailscale Ingress

Services are exposed via Tailscale Ingress (not traditional Ingress controllers):
- Tailscale operator creates proxy pods that join the tailnet
- TLS certificates are automatically provisioned via Let's Encrypt
- Access via `https://<hostname>.catfish-mountain.ts.net`

Template pattern (`templates/tailscale-ingress.yaml`):
```yaml
{{- if .Values.tailscale.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: {{ .Release.Name }}
      port:
        number: 80
  tls:
    - hosts:
        - "{{ .Values.tailscale.hostname }}"
{{- end }}
```

### Sync Behavior

ArgoCD Applications use sync-waves for dependency ordering:

| Wave | Category | Components |
|------|----------|------------|
| -4 | Foundational | cert-manager, longhorn |
| -3 | Secrets | external-secrets |
| -2 | Networking | metallb, tailscale-operator |
| -1 | Services | argocd, kubernetes-dashboard, metrics-server, traefik, tuppr |
| 0+ | Apps | user applications |

Sync-waves are also used *within* individual apps where resource ordering matters (e.g., cert-manager deploys CRDs before CRs).

### PodSecurity

Kubernetes enforces PodSecurity standards. Most namespaces use "baseline" but some require "privileged":
- `longhorn` - Storage operations require privileged access
- `metallb` - Speaker needs NET_RAW, hostNetwork for L2/ARP

Add namespace template with labels if privileged access needed:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Release.Namespace }}
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

## Common Commands

### Talos
```bash
talosctl health                           # Check cluster health
talosctl services                         # List services on node
talosctl logs kubelet                     # View kubelet logs
talosctl logs ext-tailscale               # View Tailscale extension logs
talosctl upgrade --image <url>            # Upgrade Talos
```

### Kubernetes
```bash
kubectl get applications -n argocd        # ArgoCD app status
kubectl get pods -A                       # All pods
kubectl logs -n <ns> <pod>                # Pod logs
```

### Talhelper
```bash
cd talos && ./generate-configs.sh         # Regenerate configs after talconfig.yaml changes
```

## Secrets Management

**Bootstrap secrets** (created during `bootstrap.sh`):
- **ArgoCD admin password** - `argocd-secret` in `argocd` namespace
- **Bitwarden access token** - `bitwarden-access-token` in `external-secrets` namespace

**Bitwarden-managed secrets** (via External Secrets Operator):
- **Tailscale OAuth** - `operator-oauth` in `tailscale` namespace

**Talos secrets** (gitignored):
- `talsecret.yaml` - Cluster PKI, generated by talhelper
- `.env` - Tailscale auth key for Talos extension

## Known Issues / Gotchas

1. **Metrics-server TLS**: Uses `--kubelet-insecure-tls` because kubelet certs don't include Tailscale IP SANs

2. **ArgoCD Chart.lock**: ArgoCD is the only infra chart with a Chart.lock because it uses a remote Helm dependency. Other charts use local templates or simpler dependencies.

3. **Browser certificate caching**: If a service shows insecure after certificate changes, try incognito mode or clear HSTS cache (`chrome://net-internals/#hsts`)

4. **DaemonSet retry backoff**: If a DaemonSet fails repeatedly (e.g., PodSecurity violation), fixing the issue may require `kubectl rollout restart daemonset/<name>` to clear the backoff timer

5. **Tailscale proxy pods**: Named `ts-<service>-<hash>-0` in the `tailscale` namespace

## Documentation Maintenance

When making changes to the codebase, always consider whether READMEs need to be created or updated:
- Adding a new infra component? Update `kubernetes/infra/README.md` and the repository structure in this file
- Adding a new workflow or automation? Update the root `README.md`
- Changing how something works? Check if any documentation references the old behavior

## Useful URLs

- ArgoCD: https://argocd.catfish-mountain.ts.net
- Kubernetes Dashboard: https://kube-dashboard.catfish-mountain.ts.net
- Traefik Dashboard: https://traefik.catfish-mountain.ts.net
