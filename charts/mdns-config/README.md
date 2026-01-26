# mdns-config

A reusable Helm chart for advertising services via mDNS. Creates labeled ConfigMaps that are discovered by the central mdns-advertiser deployment.

## How It Works

1. Apps include this chart as a dependency and configure their mDNS services
2. This chart creates ConfigMaps with the label `mdns.homelab.io/advertise: "true"`
3. The mdns-advertiser watches for these ConfigMaps and advertises the services

## Usage

Add as a dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: mdns-config
    version: 1.0.0
    repository: file://../../../charts/mdns-config
    condition: mdns-config.enabled
```

Configure in your `values.yaml`:

```yaml
mdns-config:
  enabled: true
  services:
    # Simple HTTP service
    - name: My App
      hostname: myapp
      ip: 192.168.0.200
      port: 80
      types:
        - type: _http._tcp

    # Service with TXT records
    - name: My MQTT Broker
      hostname: mqtt
      ip: 192.168.0.201
      port: 1883
      types:
        - type: _mqtt._tcp
          txtRecords:
            - "version=3.1.1"
```

## Values

| Key | Description | Default |
|-----|-------------|---------|
| `enabled` | Enable/disable mDNS advertisement | `true` |
| `services` | List of services to advertise | `[]` |
| `services[].name` | Display name for the service | Required |
| `services[].hostname` | mDNS hostname (without `.local`) | Required |
| `services[].ip` | IP address to advertise | Required |
| `services[].port` | Port number | Required |
| `services[].types` | List of service types | Required |
| `services[].types[].type` | Service type (e.g., `_http._tcp`) | Required |
| `services[].types[].txtRecords` | Optional TXT records | `[]` |

## Common Service Types

| Type | Description |
|------|-------------|
| `_http._tcp` | HTTP web service |
| `_https._tcp` | HTTPS web service |
| `_mqtt._tcp` | MQTT broker |
| `_smb._tcp` | SMB/CIFS file sharing |
| `_home-assistant._tcp` | Home Assistant |
| `_adisk._tcp` | Apple disk service (Time Machine) |
| `_device-info._tcp` | Device information |

## Example: Time Machine

```yaml
mdns-config:
  enabled: true
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
            - "dk0=adVN=Family,adVF=0x82"
        - type: _device-info._tcp
          txtRecords:
            - "model=TimeCapsule8,119"
```

## Resources Created

For each service in `services`:

- **ConfigMap**: `<release>-mdns-<hostname>` with label `mdns.homelab.io/advertise: "true"`
