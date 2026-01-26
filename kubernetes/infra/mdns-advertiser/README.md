# mdns-advertiser

Central mDNS advertisement service for LAN device discovery. Runs a Python script that advertises services via Zeroconf/Bonjour.

## How It Works

1. Apps configure mDNS services using the `mdns-config` shared chart
2. Each app's chart creates a ConfigMap with label `mdns.homelab.io/advertise: "true"`
3. This advertiser watches for labeled ConfigMaps across all namespaces
4. Services are advertised via mDNS on the host network

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  time-machine   │     │ home-assistant  │     │    jellyfin     │
│  (ConfigMap)    │     │  (ConfigMap)    │     │  (ConfigMap)    │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │    mdns-advertiser      │
                    │  (watches ConfigMaps)   │
                    └────────────┬────────────┘
                                 │
                         ┌───────▼───────┐
                         │   mDNS/LAN    │
                         └───────────────┘
```

## Adding mDNS to an App

See the `charts/mdns-config` README for usage. Example:

```yaml
# Chart.yaml
dependencies:
  - name: mdns-config
    version: 1.0.0
    repository: file://../../../charts/mdns-config
    condition: mdns-config.enabled

# values.yaml
mdns-config:
  enabled: true
  services:
    - name: My App
      hostname: myapp
      ip: 192.168.0.200
      port: 80
      types:
        - type: _http._tcp
```

## Debugging

Check advertiser logs:
```bash
kubectl logs -n mdns-advertiser deploy/mdns-advertiser
```

List discovered ConfigMaps:
```bash
kubectl get configmaps -A -l mdns.homelab.io/advertise=true
```

Test mDNS resolution from a Mac:
```bash
dns-sd -B _http._tcp local.
dns-sd -L "Home Assistant" _http._tcp local.
```
