# mdns-advertiser

Central mDNS advertisement service for LAN device discovery. Advertises services
via Zeroconf/Bonjour using the prebuilt `ghcr.io/bafulton/mdns-advertiser` image
(built from [`images/mdns-advertiser/`](../../../images/mdns-advertiser/)).

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

Apps can advertise via mDNS using two patterns. See [charts/README.md](../../../charts/README.md#mdns-advertisement-patterns) for choosing between them.

For direct usage of mdns-config, see [mdns-config chart](../../../charts/mdns-config/README.md). Example:

```yaml
# Chart.yaml
dependencies:
  - name: mdns-config
    version: 1.0.0
    repository: file://../../../charts/mdns-config

# values.yaml
mdns-config:
  services:
    - name: My App
      hostname: myapp
      ip: 192.168.1.200
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

`dns-sd` buffers its output when stdout isn't a terminal, so it prints nothing
when piped or captured. Give it a pty to script against it:
```bash
script -q /dev/null timeout 5 dns-sd -B _adisk._tcp local
```
