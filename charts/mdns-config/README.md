# mdns-config

A Helm library chart for advertising services via mDNS. Creates labeled ConfigMaps that are discovered by the central mdns-advertiser deployment.

## How It Works

1. Apps include this chart as a dependency and use its templates
2. Templates create ConfigMaps with the label `mdns.homelab.io/advertise: "true"`
3. The mdns-advertiser watches for these ConfigMaps and advertises the services

## Usage

Add as a dependency in your `Chart.yaml`:

```yaml
dependencies:
  - name: mdns-config
    version: 1.0.0
    repository: file://../../../charts/mdns-config
```

Create a template in your chart (e.g., `templates/mdns-configmap.yaml`):

```yaml
{{- range .Values.mdnsServices }}
{{- include "mdns-config.configmap" (dict
    "Release" $.Release
    "name" (printf "%s-mdns-%s" $.Release.Name .hostname)
    "service" .
) }}
{{- end }}
```

Configure in your `values.yaml`:

```yaml
mdnsServices:
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

Parent charts define their own values structure (typically `mdnsServices`). Each service object should contain:

| Key | Description | Required |
|-----|-------------|----------|
| `name` | Display name for the service | Yes |
| `hostname` | mDNS hostname (without `.local`) | Yes |
| `ip` | IP address to advertise | Yes |
| `port` | Port number | Yes |
| `types` | List of service type objects | Yes |
| `types[].type` | Service type (e.g., `_http._tcp`) | Yes |
| `types[].txtRecords` | Optional TXT records | No |

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
