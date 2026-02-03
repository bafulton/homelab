# Shared Helm Charts

Reusable Helm charts used as dependencies by apps in `kubernetes/infra/` and `kubernetes/apps/`.

## Charts

| Chart | Type | Description |
|-------|------|-------------|
| [bitwarden-secret](./bitwarden-secret/) | Template | Creates ExternalSecrets that pull from Bitwarden Secrets Manager |
| [gateway-route](./gateway-route/) | Gateway API | Creates HTTPRoutes for Gateway API with optional mDNS advertisement |
| [longhorn-storage](./longhorn-storage/) | Storage | Creates Longhorn PVCs with optional recurring snapshot jobs |
| [mdns-config](./mdns-config/) | Library | Advertises services via mDNS (Bonjour/Zeroconf) for LAN discovery |
| [signoz-alerts](./signoz-alerts/) | Library | Declarative SigNoz alert configuration via labeled ConfigMaps |

## Usage

Reference these charts as dependencies in your app's `Chart.yaml`:

```yaml
dependencies:
  - name: <chart-name>
    version: 1.0.0
    repository: file://../../../charts/<chart-name>
```

See each chart's README for configuration details.

## mDNS Advertisement Patterns

There are **two patterns** for advertising services via mDNS (Bonjour/Zeroconf) depending on your service type:

### Pattern 1: Via gateway-route (HTTP services with Gateway API routing)

Use this when your app has a web UI and uses Gateway API HTTPRoutes for routing.

**Benefits**:
- Combines routing + mDNS in one chart dependency
- Automatically advertises both public and LAN hostnames
- Simplifies configuration

**When to use**:
- HTTP/HTTPS services with web UIs
- Services that need both Gateway API routing AND mDNS discovery
- Examples: jellyfin, home-assistant

**Chart.yaml**:
```yaml
dependencies:
  - name: gateway-route
    version: 1.0.0
    repository: file://../../../charts/gateway-route
  # Note: mdns-config is NOT listed here - gateway-route includes it as its own dependency
```

**values.yaml**:
```yaml
gateway-route:
  routes:
    - name: public-lan
      hostnames:
        - myapp.fultonhuffman.com  # Public via Cloudflare Tunnel
        - myapp.local              # LAN via mDNS
      service:
        name: myapp-server
        port: 8080
      mdns:                        # Optional mDNS advertisement
        name: My App               # Display name in Finder/network browsers
        ip: 192.168.0.200          # Gateway MetalLB IP (192.168.0.200)
```

**How it works**:
1. `gateway-route` includes `mdns-config` as its own dependency
2. When you set `.routes[].mdns`, gateway-route passes the config to mdns-config
3. mdns-config creates a labeled ConfigMap
4. The central mdns-advertiser discovers the ConfigMap and advertises the service

### Pattern 2: Direct mdns-config (Non-HTTP services)

Use this when your app uses a MetalLB LoadBalancer for non-HTTP protocols and only needs mDNS discovery (no Gateway API routing).

**Benefits**:
- Lighter weight (no HTTPRoute resources created)
- Direct control over mDNS configuration
- Can advertise multiple service types

**When to use**:
- Non-HTTP protocols (MQTT, SMB, custom TCP/UDP services)
- Services that have their own LoadBalancer but need LAN discovery
- Services that need custom mDNS service types or TXT records
- Examples: time-machine (SMB), mosquitto (MQTT)

**Chart.yaml**:
```yaml
dependencies:
  - name: mdns-config
    version: 1.0.0
    repository: file://../../../charts/mdns-config
```

**values.yaml**:
```yaml
mdnsServices:
  - name: My App                   # Display name
    hostname: myapp                # Becomes myapp.local
    ip: 192.168.0.201              # Service's MetalLB LoadBalancer IP
    port: 8080
    types:                         # Optional: Service types (defaults to _http._tcp)
      - type: _http._tcp
      - type: _myapp._tcp
    txt:                           # Optional: TXT records for service metadata
      key: value
```

**How it works**:
1. Your Chart.yaml lists mdns-config directly
2. mdns-config creates a labeled ConfigMap with your service details
3. The central mdns-advertiser discovers the ConfigMap and advertises the service

### Why Two Patterns?

The distinction exists because:
- **HTTP services** typically need both routing (Gateway API) AND discovery (mDNS), so combining them reduces duplication
- **Non-HTTP services** only need discovery (mDNS) and don't benefit from HTTPRoutes

Both patterns use the same underlying mdns-config library chart and create ConfigMaps that are discovered by the central `mdns-advertiser` deployment.

### Choosing a Pattern

```
Does your service use Gateway API HTTPRoutes?
├─ Yes → Use Pattern 1 (gateway-route with .mdns field)
└─ No  → Use Pattern 2 (direct mdns-config)
```

### Important: ArgoCD Dependency Resolution

When using Pattern 1 (gateway-route with mDNS), you **must explicitly list mdns-config** in your Chart.yaml for ArgoCD to resolve dependencies correctly:

```yaml
dependencies:
  - name: gateway-route
    version: 1.0.0
    repository: file://../../../charts/gateway-route
  - name: mdns-config        # Required when using .routes[].mdns
    version: 1.0.0
    repository: file://../../../charts/mdns-config
```

**Important**: Only include `mdns-config` if you're actually using the `.routes[].mdns` field in your values.yaml. If you're only using gateway-route for routing without mDNS advertisement (like traefik), you don't need to list mdns-config.
