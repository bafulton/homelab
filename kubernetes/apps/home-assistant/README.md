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

The Matter Server also uses hostNetwork and communicates with Home Assistant via WebSocket at `ws://matter-server:5580/ws`.

## Storage

| PVC | Size | Storage Class | Backup |
|-----|------|---------------|--------|
| `home-assistant-config` | 5Gi | longhorn-emmc | Daily (5 retained) |
| Matter Server data | 1Gi | longhorn-emmc | No |

## Metrics

Exposes Prometheus metrics at `/api/prometheus` for SigNoz integration. The endpoint requires no authentication for cluster-internal scraping.

## GitOps Packages

Home Assistant automations, scripts, and sensors are managed via GitOps using HA's [packages](https://www.home-assistant.io/docs/configuration/packages/) feature. Package files in `files/packages/` are automatically mounted into the container.

### Current Packages

| Package | Purpose |
|---------|---------|
| `light_effects.yaml` | Color cycling effects for smart bulbs |
| `network_sensors.yaml` | Network sensors |
| `sensor_fixes.yaml` | Temporary workarounds for upstream bugs |

### Adding a New Package

1. Create a YAML file in `files/packages/`:
   ```yaml
   # files/packages/my-feature.yaml
   automation:
     - alias: "My Automation"
       trigger:
         # ...
   ```
2. Commit and push - ArgoCD syncs automatically
3. Home Assistant reloads the package on restart

### Dashboard Buttons for Light Effects

Add buttons to your HA dashboard that set the `input_select.light_effect` entity. Example button:

```yaml
type: button
name: Rainbow
icon: mdi:looks
tap_action:
  action: call-service
  service: input_select.select_option
  target:
    entity_id: input_select.light_effect
  data:
    option: Rainbow  # Use any option from light-effects.yaml
```

Use `script.reset_lights_to_normal` to turn off effects and restore normal lighting.

## Initial Setup

1. Wait for ArgoCD to sync the app
2. Access `https://home-assistant.catfish-mountain.ts.net`
3. Create your admin account
4. Add integrations for your smart devices

## Adding Matter Devices

1. Go to Settings > Devices & Services > Add Integration
2. Search for "Matter"
3. Configure WebSocket URL: `ws://matter-server:5580/ws`
4. Commission devices through the Matter Server

## BLE Sensors (OpenMQTTGateway)

An M5Stack running OpenMQTTGateway decodes BLE advertisements from Govee sensors and publishes to MQTT. Home Assistant auto-discovers these sensors.

### Flashing the M5Stack

1. Go to: https://docs.openmqttgateway.com/upload/web-install.html
2. Select **M5Stack** board type
3. Select **development** version for latest device support
4. Click "Install" and select the serial port
5. Choose "Erase device" to start fresh

### M5Stack Configuration

After flashing, the M5Stack creates a WiFi AP:

1. Connect to the `OpenMQTTGateway` WiFi network
2. Go to `192.168.4.1` in your browser
3. Configure:
   - **WiFi**: Your home network credentials
   - **MQTT Host**: `mosquitto.local` or `192.168.0.202`
   - **MQTT Port**: `1883`
   - **No username/password** (anonymous access enabled)

### Supported Devices

The Theengs decoder library supports many BLE devices including:
- Govee temperature/humidity sensors (H5074, H5075, H5106, etc.)
- Govee air quality monitors (H5106, H5140)
- SwitchBot devices
- Xiaomi/Mijia sensors
- Many more: https://decoder.theengs.io/devices/devices.html
