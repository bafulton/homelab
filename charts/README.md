# Shared Helm Charts

Reusable Helm charts used as dependencies by apps in `kubernetes/infra/` and `kubernetes/apps/`.

## Charts

| Chart | Type | Description |
|-------|------|-------------|
| [bitwarden-secret](./bitwarden-secret/) | Template | Creates ExternalSecrets that pull from Bitwarden Secrets Manager |
| [gateway-route](./gateway-route/) | Gateway API | Creates HTTPRoutes for Gateway API with optional mDNS advertisement |
| [local-storage](./local-storage/) | Storage | Creates static hostPath PVs/PVCs with optional VolSync backups |
| [longhorn-storage](./longhorn-storage/) | Storage | Creates Longhorn PVCs with optional recurring snapshot jobs |
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

## mDNS Advertisement

The central [mdns-advertiser](../kubernetes/infra/mdns-advertiser/README.md)
publishes `.local` names from annotations on the objects being advertised, so
records follow those objects and no IP is copied into values. There are two
ways to opt in, depending on how the app is reached.

### Web apps: `mdns` on a gateway-route route

For an app behind the apps Gateway, set `mdns` on the route that serves its
`.local` hostname. gateway-route annotates the HTTPRoute, and the advertiser
publishes each `.local` hostname at the Gateway's address (the LAN VIP):

```yaml
gateway-route:
  routes:
    - name: public-lan
      access: apps
      hostnames:
        - myapp.fultonhuffman.com  # Public via Cloudflare Tunnel
        - myapp.local              # LAN via mDNS
      service:
        name: myapp-server
        port: 8080
      mdns:
        name: My App               # Display name in Finder and network browsers
        port: 443                  # Optional, default 80
        types:                     # Optional, default _http._tcp
          - type: _https._tcp
```

Examples: Jellyfin, Home Assistant, BottleShip.

### Anything with its own LoadBalancer: Service annotations

For a non-HTTP service with its own MetalLB address (MQTT, SMB, game servers),
annotate the Service. The advertiser publishes it at the Service's load
balancer address:

```yaml
service:
  annotations:
    metallb.io/loadBalancerIPs: "192.168.1.202"
    mdns.homelab.io/hostname: mosquitto      # mosquitto.local
    mdns.homelab.io/name: Mosquitto
    mdns.homelab.io/types: _mqtt._tcp
```

For types with TXT records, `mdns.homelab.io/types` takes a JSON list of
`{"type": ..., "txtRecords": [...]}` instead of a comma list, and
`mdns.homelab.io/ip` publishes a name at another address. Examples: Mosquitto,
Time Machine, and Gameplane's Minecraft servers, whose annotations come from
an admission policy. See the
[advertiser's README](../kubernetes/infra/mdns-advertiser/README.md#annotations)
for every annotation.

## Placement (node location)

Nodes carry a `homelab.io/location` label — `local` for on-prem/LAN nodes
(beelink, rpi5), `remote` for cloud nodes (e.g. `ocifree`). It expresses *where
a workload is allowed to run*, orthogonal to the disk-type labels
(`storage.homelab.io/emmc|nvme|usb`) that pin storage.

**Default is "anywhere": most workloads set no location selector** and the
scheduler is free to place them on any node — including a remote node, which is
how a cloud node absorbs overflow and relieves memory pressure at home.

Only pin the exceptions, via the upstream chart's own `nodeSelector`:

```yaml
# values.yaml — keep a workload on LAN nodes only
<upstream-chart>:
  nodeSelector:
    homelab.io/location: local
```

Pin `location: local` when a workload:

- is **hostNetwork** and needs the LAN (Home Assistant, mDNS advertiser,
  Matter/Chromecast bridges),
- does **L2/ARP** for the LAN (MetalLB speaker/controller/frr-k8s),
- is backed by **Longhorn** storage and **latency-sensitive** — a `config`
  volume can attach on a remote node (the replicas stay on the local nodes and
  the node reaches them over Tailscale), but every read and write then crosses
  the WAN, or
- has strong **data gravity** to a local store (SigNoz OTel collector → local
  ClickHouse).

**Don't** pin `location: local` on a workload already pinned to a
local-exclusive constraint — a disk-type label (`storage.homelab.io/*`) or a
specific `kubernetes.io/hostname` (garage→rpi5, jellyfin, time-machine,
argocd-dex). That selector is already more specific than location; a second key
is redundant noise. Pin on the most specific real constraint.

Node agents (`node-health`, `smartctl-exporter`, node-feature-discovery, OTel
node collectors) stay unpinned: they *should* run on every node, remote
included, so the cloud node is monitored like any other.

Longhorn *storage* is kept off remote nodes not with a chart `nodeSelector`
(changing Longhorn's `systemManagedComponentsNodeSelector` on a running cluster
forces a volume detach), but by marking the remote Longhorn node
`allowScheduling: false` with no disk at join time. Longhorn's components still
run there, so pods on a remote node can use `config` PVCs. The strict-local
classes (`state`, `scratch`) are already pinned to beelink by hostname.
