# Infrastructure Components

This directory contains Helm charts for cluster infrastructure, deployed via ArgoCD.

## Components

| Component | Purpose | Exposed via |
|-----------|---------|-------------|
| [argocd](./argocd) | GitOps continuous delivery - syncs cluster state from this repo | *.catfish-mountain.com |
| [cert-manager](./cert-manager) | TLS certificate management (Let's Encrypt + homelab CA) | - |
| [cloudflared](./cloudflared) | Cloudflare Tunnel for secure public access to selected services | - |
| [cluster-maintenance](./cluster-maintenance) | Cluster-level maintenance utilities (pod cleanup) | - |
| [coredns](./coredns) | Split DNS for *.catfish-mountain.com via Tailscale | *.ts.net |
| [external-secrets](./external-secrets) | Syncs secrets from Bitwarden into Kubernetes | - |
| [garage](./garage) | S3-compatible object storage - backup target for Longhorn and VolSync | *.catfish-mountain.com |
| [intel-device-plugins](./intel-device-plugins) | Intel GPU device plugins for QuickSync hardware transcoding | - |
| [kube-state-metrics](./kube-state-metrics) | Kubernetes object state metrics (deployments, pods, PVCs) | - |
| [longhorn](./longhorn) | Distributed block storage for persistent volumes | - |
| [mdns-advertiser](./mdns-advertiser) | Publishes services to LAN via mDNS/Bonjour | hostNetwork |
| [metallb](./metallb) | Load balancer for bare-metal - assigns LAN IPs | - |
| [metrics-server](./metrics-server) | Resource metrics for HPA, VPA, and `kubectl top` | - |
| [mosquitto](./mosquitto) | MQTT message broker for IoT devices | MetalLB |
| [node-exporter](./node-exporter) | Node hardware metrics (CPU, memory, disk, temperature) | - |
| [node-health](./node-health) | Cluster health monitoring via healthchecks.io | - |
| [reloader](./reloader) | Auto-restarts pods when ConfigMaps/Secrets change | - |
| [signoz](./signoz) | Observability platform (metrics, logs, traces) | *.catfish-mountain.com |
| [signoz-k8s-infra](./signoz-k8s-infra) | Kubernetes metrics collection for SigNoz | - |
| [smartctl-exporter](./smartctl-exporter) | Disk SMART health metrics (NVMe, USB, SD cards) | - |
| [snapshot-crds](./snapshot-crds) | VolumeSnapshot CRDs (cluster-level primitive required by VolSync) | - |
| [tailscale-operator](./tailscale-operator) | Exposes services on your Tailscale network | - |
| [time-machine](./time-machine) | Time Machine backup server for macOS | MetalLB |
| [traefik](./traefik) | Ingress admission policies and legacy retirement | - |
| [traefik-admin](./traefik-admin) | Shared administrative gateway | Tailscale administrator grant, TCP 443 |
| [traefik-apps](./traefik-apps) | Household and public application gateway | LAN VIP, Cloudflare, Tailscale/OCI |
| [tuppr](./tuppr) | Automated Talos and Kubernetes upgrade orchestration | - |
| [volsync](./volsync) | Asynchronous PVC replication for scheduled restic backups to Garage | - |

## Networking Overview

The [ingress migration runbook](traefik/MIGRATION.md) coordinates migration from the legacy
shared gateway. The topology below describes the target configuration.

```mermaid
flowchart LR
    admins[Authorized Tailscale administrators] --> admin[traefik-admin:443]
    admin --> dashboards[Administrative ClusterIP backends]
    lan[Household LAN] --> vip[MetalLB 192.168.1.200]
    vip --> apps[traefik-apps]
    internet[Public Internet] --> cf[Cloudflare Tunnel]
    internet --> edge[OCI edge forwarder]
    cf --> apps
    edge -->|Tailscale port 8443| apps
    members[Tailnet members] -->|80/443| apps
    apps --> services[Household/public backends]
```

Private DNS names alone do not authorize access. Administrative names resolve to
the separate `cluster-admin` proxy, tagged `tag:k8s-admin`; only
`group:homelab-admins` may connect. Household/public applications use
`traefik-apps` and retain existing application authentication. Home Assistant,
Jellyfin and Pocket ID retain mixed-use capabilities and application roles.

### CoreDNS (built into Kubernetes)
Provides DNS for pods and services inside the cluster. When a pod calls `http://my-service:8080`, CoreDNS resolves `my-service` to the Service's ClusterIP.

### Tailscale Split DNS

Routes `*.catfish-mountain.com` queries to `cluster-dns`. Explicit administrative
A records target the assigned `cluster-admin` Tailscale IP; the apex/wildcard
target the assigned `cluster-apps` IP. The rollout helper populates these records
after proxy provisioning. Both are shared gateway proxies,
not individual application machines. See [CoreDNS](coredns/README.md).
Ordinary LAN clients cannot reach administrative interfaces through the apps VIP,
even when supplying their hostnames.

### Cloudflare Tunnel
Routes specific public subdomains (defined in `opentofu/cloudflare/variables.tf`) to the cluster via secure tunnel. Most domains are **private by default** - only explicitly configured subdomains are public.

**Use for public services:**
- Personal websites and blogs
- Services you want publicly accessible
- Anything that should work for non-Tailscale users

### MetalLB
Assigns real LAN IPs to `LoadBalancer` Services. Without it (or a cloud provider), LoadBalancer services stay in `Pending` forever.

**Use MetalLB for:**
- The Traefik Gateway (gets a stable LAN IP)
- Non-HTTP services (SMB, databases, game servers)
- Services that need dedicated IPs

### Traefik Gateway
Kubernetes Gateway API implementation that routes HTTP(S) traffic based on Gateway API HTTPRoute resources. Household/public HTTP services use `traefik-apps`, including LAN VIP `192.168.1.200`. Administrative routes use the separate `traefik-admin` Gateway and Tailscale proxy.

**Why use a Gateway?** Shares one IP across many services:

```mermaid
flowchart LR
    ip[192.168.1.200] --> gateway[Traefik Gateway]
    gateway -->|app1.fultonhuffman.com| app1[app1-service]
    gateway -->|app2.local| app2[app2-service]
    gateway -->|app3.yak-shave.com| app3[app3-service]
```

Services use the [gateway-route](../../charts/gateway-route/README.md) shared chart to create HTTPRoute resources. Apps routes may combine public and household LAN names. Administrative names use separate admin-class routes. See [traefik-admin](./traefik-admin/README.md) and [traefik-apps](./traefik-apps/README.md).

### hostNetwork (for mDNS services)

Some services need mDNS/Bonjour for device discovery. mDNS uses multicast UDP which doesn't work across Kubernetes network namespaces. For these services, we use `hostNetwork: true` to bind directly to the node's network.

**Use hostNetwork for:**
- The central mDNS advertiser (publishes HTTP and non-HTTP LAN service names)
- Home Assistant (discovers IoT devices like Chromecast, HomeKit, ESPHome via mDNS)

**Trade-offs:**
- Ports bind directly to the node IP (e.g., `192.168.1.99:445`)
- Less "Kubernetes-native" but necessary for mDNS
- Only use for services that genuinely require multicast discovery

## Choosing an Exposure Method

```
"What are the access requirements for this service?"

├── HTTP service (web UI, API)?
│   └── Use gateway-route chart → creates HTTPRoute
│
│       Choose hostname(s):
│       ├── Administrative access? → traefik-admin, *.catfish-mountain.com
│       ├── Public access? → *.fultonhuffman.com (or other public domain)
│       └── LAN discovery? → *.local (with mDNS)
│
│       Public/LAN names may share apps routes; admin routes stay separate.
│
├── Non-HTTP service (SMB, database, game server)?
│   └── Use MetalLB LoadBalancer → gets dedicated LAN IP
│
└── Needs mDNS discovery (auto-discovery on LAN)?
    └── Use hostNetwork → binds to node IP
```

### Quick Reference

| Service Type | Method | Example Hostname |
|--------------|--------|------------------|
| Admin UIs (ArgoCD, dashboards) | gateway-route, access: admin | `argocd.catfish-mountain.com` |
| Public sites (blogs, portfolios) | gateway-route | `blog.fultonhuffman.com` |
| LAN web apps (Jellyfin, media) | gateway-route with mDNS | `media.local` |
| LAN non-HTTP (databases, SMB) | MetalLB LoadBalancer | `192.168.1.x:port` |
| LAN discovery (Time Machine) | MetalLB + mdns-config | Auto-discovered |

### Multi-Hostname Example

Most services use a single HTTPRoute with multiple hostnames for different access methods:

```yaml
gateway-route:
  routes:
    - name: media
      access: apps
      listeners: [web, edge]
      hostnames:
        - media.fultonhuffman.com      # Public (this one via the OCI edge forwarder)
        - media.local                  # LAN via mDNS
      service:
        name: jellyfin
        port: 8096
      mdns:  # Optional: advertise via Bonjour
        name: Media Server
        ip: 192.168.1.200
        port: 80
```

**Note:** Some services need multiple exposure methods. For example, Home Assistant might use:
- `hostNetwork: true` (to discover IoT devices via mDNS)
- `gateway-route` (for web UI access at `home.local`)
