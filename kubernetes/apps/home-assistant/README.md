# Home Assistant

Smart home platform for local control of IoT devices. Integrates with Kasa, Meross, SwitchBot, Matter, and many other ecosystems.

## Access

| Method | URL | Use Case |
|--------|-----|----------|
| LAN | `http://home.local` | Local access on home network |
| Tailscale | `https://home-assistant.catfish-mountain.ts.net` | Remote access from anywhere |

## Components

| Component | Purpose |
|-----------|---------|
| Home Assistant | Core smart home platform |
| AirCast | AirPlay bridge for Chromecast speakers |
| Matter Server | Controller for Matter smart home devices |

## Network Configuration

Uses `hostNetwork: true` for device discovery:
- **mDNS/Bonjour** - Discovers HomeKit, Chromecast, ESPHome devices
- **SSDP** - Discovers UPnP devices (Kasa, Meross, Hue bridges)
- **Matter** - Local network discovery for Matter devices

The Matter Server also uses hostNetwork and communicates with Home Assistant via WebSocket at `ws://localhost:5580/ws`.

## Storage

| PVC | Size | Storage Class | Backup |
|-----|------|---------------|--------|
| `home-assistant-config` | 5Gi | longhorn-emmc | Daily (5 retained) |
| Matter Server data | 1Gi | longhorn-emmc | No |

## Metrics

Exposes Prometheus metrics at `/api/prometheus` for SigNoz integration. The endpoint requires no authentication for cluster-internal scraping.

## Initial Setup

1. Wait for ArgoCD to sync the app
2. Access `https://home.catfish-mountain.ts.net`
3. Create your admin account
4. Add integrations for your smart devices

## Adding Matter Devices

1. Go to Settings > Devices & Services > Add Integration
2. Search for "Matter"
3. Configure WebSocket URL: `ws://localhost:5580/ws`
4. Commission devices through the Matter Server
