# Infrastructure Components

This directory contains Helm charts for cluster infrastructure.

## Networking Overview

Understanding how traffic flows in a bare-metal Kubernetes cluster:

```mermaid
flowchart TB
    subgraph internet[Internet]
        X[No public exposure]
    end

    subgraph tailnet[Your Tailnet]
        laptop[Laptop / Phone]
    end

    subgraph lan[Local Network]
        landevice[Devices on LAN]
    end

    subgraph k8s[Kubernetes Cluster]
        subgraph ingress[Ingress Layer]
            ts[Tailscale Operator]
            traefik[Traefik]
            metallb[MetalLB]
        end

        svc[Services]
        pods[Pods]
        coredns[CoreDNS]

        ts -->|exposes on tailnet| svc
        traefik -->|routes by host/path| svc
        metallb -->|assigns LAN IPs| traefik
        svc --> pods
        coredns -.->|DNS for pod-to-pod| pods
    end

    internet -.->|blocked| k8s
    laptop -->|argocd.tailnet.ts.net| ts
    landevice -->|192.168.x.x| metallb
```

### CoreDNS (built into Kubernetes)
Provides DNS for pods and services inside the cluster. When a pod calls `http://my-service:8080`, CoreDNS resolves `my-service` to the Service's ClusterIP.

### Tailscale Operator
Exposes services directly on your Tailscale network - no port forwarding, no public IPs. Services get a `<name>.<tailnet>.ts.net` hostname accessible from any device on your tailnet.

**Use Tailscale for services you want accessible from anywhere** - laptop at a coffee shop, phone on cellular, etc:
- ArgoCD, dashboards, admin UIs
- Services you want to access remotely

### MetalLB
Assigns real LAN IPs to `LoadBalancer` Services. Without it (or a cloud provider), LoadBalancer services stay in `Pending` forever.

**Use MetalLB for LAN-only services** - things you only want accessible when physically on your home network:
- Time Machine backup targets (NFS/SMB) - keeps backup traffic local and fast
- Media servers for local streaming
- Anything that shouldn't be reachable remotely

### Traefik
Ingress controller that routes HTTP(S) traffic to Services based on hostname/path rules.

**Why use an ingress controller?** Without one, each HTTP service would need its own MetalLB IP. With Traefik, many services share one IP:

```mermaid
flowchart LR
    ip[192.168.1.200] --> traefik[Traefik]
    traefik -->|app1.homelab.local| app1[app1-service]
    traefik -->|app2.homelab.local| app2[app2-service]
    traefik -->|app3.homelab.local/api| app3[app3-service]
```

**In this homelab**, most services are exposed via Tailscale (which handles its own routing). Traefik is useful for:
- LAN-only HTTP services that shouldn't be on Tailscale
- Routing multiple LAN services through a single MetalLB IP
