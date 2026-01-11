# mDNS Advertiser

Publishes Kubernetes services to the LAN via mDNS/Bonjour, enabling auto-discovery from devices like Macs, iPhones, and other Bonjour-aware clients.

## Why?

Kubernetes services are isolated from the LAN by default. Even with MetalLB providing a stable IP, LAN devices can't discover services via mDNS because:

1. **mDNS uses multicast** - Multicast traffic doesn't cross network boundaries
2. **Pods can't broadcast to LAN** - Unless using `hostNetwork: true`

This chart solves this by running a Python script with `hostNetwork` that uses the zeroconf library to publish mDNS records pointing to your MetalLB IPs.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                              │
│  ┌─────────────────────┐    ┌─────────────────────┐         │
│  │   Your Service      │    │   mDNS Advertiser   │         │
│  │ (normal networking) │    │   (hostNetwork)     │         │
│  └──────────┬──────────┘    │                     │         │
│             │               │  Publishes:         │         │
│             ▼               │  myservice.local    │         │
│  ┌─────────────────────┐    │    → 192.168.0.x    │         │
│  │ MetalLB: 192.168.0.x│    └──────────┬──────────┘         │
│  └─────────────────────┘               │                    │
└─────────────────────────────────────────┼────────────────────┘
                                         │ mDNS multicast
                                         ▼
                               ┌───────────────────┐
                               │    LAN Devices    │
                               └───────────────────┘
```

## Usage

Add as a dependency in your Chart.yaml:

```yaml
dependencies:
  - name: mdns-advertiser
    version: 1.0.0
    repository: file://../../../charts/mdns-advertiser
```

Configure services in values.yaml:

```yaml
mdns-advertiser:
  services:
    - name: My Service        # Display name in Finder/discovery
      hostname: myservice     # Becomes myservice.local
      ip: 192.168.0.201       # MetalLB IP
      port: 8080
      types:
        - type: _http._tcp    # Service type
        - type: _custom._tcp
          txtRecords:
            - "key=value"
```

## Time Machine Example

```yaml
services:
  - name: Time Machine
    hostname: timemachine
    ip: 192.168.0.201
    port: 445
    types:
      - type: _smb._tcp
      - type: _adisk._tcp
        txtRecords:
          - "sys=adVF=0x100"
          - "dk0=adVN=Time Machine,adVF=0x82"
      - type: _device-info._tcp
        txtRecords:
          - "model=TimeCapsule8,119"
```

## Common Service Types

| Service | Type | Notes |
|---------|------|-------|
| SMB/CIFS | `_smb._tcp` | File sharing |
| Time Machine | `_adisk._tcp` | Apple disk discovery |
| HTTP | `_http._tcp` | Web services |
| Home Assistant | `_home-assistant._tcp` | HA discovery |
| AirPlay | `_airplay._tcp` | Audio/video streaming |
| SSH | `_ssh._tcp` | Remote shell |

## Requirements

- The deployment namespace needs `pod-security.kubernetes.io/enforce: privileged` (for hostNetwork)
- MetalLB or similar for stable service IPs
