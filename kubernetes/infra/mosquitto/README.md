# Mosquitto

Eclipse Mosquitto MQTT broker for IoT device communication. Serves as the message bus for Theengs Gateway (BLE sensor data) and Home Assistant.

## Access

| Method | Address | Use Case |
|--------|---------|----------|
| mDNS | `mosquitto.local:1883` | Theengs Gateway, ESP32 devices |
| Kubernetes DNS | `mosquitto.mosquitto.svc.cluster.local:1883` | Home Assistant (in-cluster) |
| Direct IP | `192.168.0.202:1883` | Fallback |

## Configuration

- **Authentication**: Anonymous (LAN access only, no external exposure)
- **Protocol**: MQTT on port 1883 (no TLS)
- **Persistence**: Enabled for retained messages

## Storage

| PVC | Size | Storage Class |
|-----|------|---------------|
| `mosquitto-data` | 1Gi | longhorn-emmc |

## Home Assistant Integration

1. Go to Settings > Devices & Services > Add Integration
2. Search for "MQTT"
3. Configure broker: `mosquitto.mosquitto.svc.cluster.local`
4. Port: `1883`
5. No username/password required

## Theengs Gateway Setup

Configure your ESP32 running Theengs Gateway to connect to:
- **MQTT Host**: `mosquitto.local` (or `192.168.0.202`)
- **MQTT Port**: `1883`
- **No authentication required**

Theengs Gateway will decode BLE advertisements from Govee sensors and publish to MQTT topics that Home Assistant auto-discovers.
