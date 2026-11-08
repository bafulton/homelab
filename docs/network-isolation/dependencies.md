# Dependency matrix and trust boundaries

Directions below describe new connections; replies should be statefully allowed. These are configuration-derived dependencies corroborated by live workload/Service metadata, **not a captured flow inventory**. Ports marked “verify” require protocol/traffic discovery before writing restrictive rules. No unverified port is an activation-ready allowlist. See the generated endpoint and exception inventories below.

| Source / owner | Required destination | Protocol / port | Evidence and validation still needed |
|---|---|---|---|
| Ordinary pods | kube-system/kube-dns | UDP + TCP/53 | Harness exercises both. Preserve CoreDNS→host resolver `169.254.116.108`; do not give ordinary apps direct unrestricted host/tailnet DNS access. |
| cloudflared | traefik-apps; Cloudflare edge | Gateway HTTP; outbound tunnel TCP/UDP/7844 and HTTPS as required | Cluster/Cloudflare ingress config; verify actual tunnel fallback and DNS. |
| OCI edge forwarder | traefik-apps edge listener | TCP/8443, exact public SNI entrance | Existing edge allowlist/Tailscale grant; test media and games TLS/WebSocket/download paths. Forwarder is outside Kubernetes NetworkPolicy scope. |
| LAN clients / tailscale proxies | Their respective gateway or non-HTTP service | Gateway listeners; MQTT/1883; SMB/445; DNS/53 | Preserve entry source identity through Service NAT/proxying. Tailnet grants remain independently enforced. |
| traefik-apps | Public/household HTTP backends | See Service→container port table | Routes in wrapper values; test public, local HTTP/HTTPS, OIDC callback and auth middleware. |
| traefik-admin | Administrative backends | See table | Dedicated gateway and admin Tailscale grant; app pods must not acquire gateway-equivalent access. |
| BottleShip oauth2-proxy / local proxy | Pocket ID issuer; local app/auth callbacks | HTTPS/443 externally or current local issuer route; proxy/4180 | `apps/bottleship/templates/oauth2-proxy.yaml`; test discovery, JWKS, token exchange, expiry, both public/local issuers. Browser redirects are browser traffic, not necessarily server egress. |
| Jellyfin | Pocket ID and metadata providers | HTTPS; exact destinations verify from runtime config | SSO partly configured on PVC, not fully in Git; verify sign-in/refresh, library lookup and media playback. Do not invent an exhaustive allowlist from values alone. |
| Home Assistant | Matter server, MQTT, Pocket ID/cloud integrations, LAN devices | Matter WS/5580; MQTT/1883; device discovery/control ports verify | hostNetwork; dynamic integration state on PVC. Requires separate host/LAN boundary treatment. |
| Aircast / Matter server | LAN media/Matter devices and multicast | mDNS/5353, SSDP/1900 and protocol-specific unicast verify | hostNetwork; device addresses/ports inventory remains open. |
| Pocket ID | SQLite on PVC; optional external services | No standalone database network endpoint; outbound requirements verify | `infra/pocket-id/templates/deployment.yaml`; test login and account flows. Inventory runtime SMTP/webhook/update settings before egress restriction. |
| yak-shave | No backend dependency declared | DNS if required; other egress unproven | Best initial ordinary-pod canary; verify serving behavior before denying egress. |
| Argo controllers/server/repo/Dex | API, Redis, repo RPC, OIDC, GitHub and chart registries | API/6443 (Service/443); Redis/6379; repo/8081; Dex/5556,5557; HTTPS | Existing policies cover internal ingress selectively. Enumerate registries from all Chart.yaml, Git sources, webhook and notification configuration; test actual reconciliation. |
| cert-manager | API, DNS recursive/auth servers, ACME + Cloudflare API | API; TCP/443; UDP/TCP/53 as configured | Test staging DNS-01 and renewal path, plus webhook reachability from API server. |
| External Secrets / Bitwarden SDK | API, Bitwarden service and upstream API | API; service TLS + upstream HTTPS (verify Service port) | SecretStore template and live Service; test a non-disruptive refresh and SDK certificate path. |
| Tailscale operator/proxy pods | API, tailnet peers/control/DERP | HTTPS and negotiated Tailscale paths, verify | Privileged proxies; Talos Tailscale extension is outside pod policy. Verify admin, apps and DNS proxies independently. |
| Longhorn manager/CSI/engines/replicas | API, peer storage components and node iSCSI | 9500/9501/9502/9503; iSCSI/3260; dynamic instance-manager/engine ports verify | Never infer all storage ports from declared containerPorts. Validate PVC attach/read/write, replica rebuild, dynamic jobs and cross-site attachment without rebooting nodes. |
| Longhorn backup jobs; VolSync mover jobs; etcd backup | garage.garage.svc.cluster.local | TCP/3900 S3 | Backup values/shared charts; mover jobs run in workload namespaces, not necessarily volsync-system. Verify backup and scratch restore of each mechanism. |
| Garage web UI/bootstrap | Garage API/admin/RPC and peer resources | 3900/3901/3903/3909 as applicable; see rendered/live metadata | Single Garage data node on rpi5. Admin/bootstrap access is distinct from backup writers; verify admin token API endpoints and hooks. |
| SigNoz collectors | Annotated metrics endpoints, HA, kubelet/API, SigNoz collector | Metrics ports below; HA Service/80→8123; kubelet/10250; OTLP/4317,4318 | `signoz-k8s-infra/values.yaml`; preserve scraping from actual agent/deployment labels. Home Assistant metrics require token. |
| SigNoz backend/collector | ClickHouse, ZooKeeper, internal APIs; Gmail SMTP | ClickHouse/8123,9000; ZooKeeper/2181; internal ports verify; SMTP/587 | Scope database clients explicitly. Verify alerts, ingestion, queries, dashboard sync and migrations. |
| metrics-server, kube-state-metrics, reloader, descheduler, node-health, tuppr, maintenance, VolSync | API and component-specific endpoints | API/443→6443; kubelets for metrics-server; node-health HTTPS healthchecks | Verify actual controllers, hooks, CronJobs and Healthchecks egress; ephemeral jobs will not all appear in a pod snapshot. |
| node-exporter/smartctl exporter | Scraper ingress / host devices | TCP/9100 and declared exporter ports | Host network/device privileges, not ordinary app trust. |
| mDNS advertiser | API watch, LAN multicast and gateway VIP advertisements | API; UDP/5353 | hostNetwork, LAN discovery is outside ordinary pod enforcement. |
| MetalLB/FRR | API, L2 LAN and configured routing peers | ARP/NDP; memberlist/routing as configured | Host network + network capabilities; preserve Service VIPs. |
| subnet-route-steering / Flannel / kube-proxy | Node routes, VXLAN and Service forwarding | Flannel UDP/4789; routing/firewall programming | Privileged/network capabilities, outside ordinary workload isolation. Preserve steering priorities 5260 before Tailscale 5270. |
| Intel device plugins / NFD | Kubelet sockets, API / hardware discovery | Node-local sockets; API as configured | Host mounts/device access remain a trust boundary; inspect generated pods and admission privileges. |

## Real-workload acceptance probes to prepare before rollout

For each app under restriction, pair a positive functional check with an unrelated-pod negative TCP check to its direct pod and Service addresses. Run negative database/admin checks from an ordinary application pod, not a gateway or privileged debug pod. Include gateway/admin VIP and tailnet-name paths as possible alternate entrances. Authentication failures are not evidence of network denial.

Use `check.py --targets /tmp/cat6-targets.json` with a JSON list such as `[{"host":"KNOWN_LISTENING_LAN_IP","port":PORT}]` (substitute actual values). All listed endpoints must be reachable during baseline and from the allowed control client. During the egress phase the restricted client must lose access. Include a LAN listener, a tailnet administrative endpoint, and an unrelated database listener after verifying each target is safe to probe. This proves synthetic egress blocking; required per-application device integrations still need positive checks from those applications. No LAN endpoint was probed by this preflight.

DNS, API, storage operations and end-user functionality must be observed while policy is active, rather than assumed from an engine's conformance claim. Record packet source identity before/after NAT for gateway, tailnet proxy, API, and cross-site paths. Home-to-home paths must remain on LAN during the outage test; run WAN/OCI loss exercises in the separate resilience workstream.

## Observed Service ports (2026-11-07)

This table includes all collected Services. A Service port is not itself a complete firewall rule; resolve target ports and selectors against pods.

| Namespace | Service | Service port → target port |
|---|---|---|
| argocd | argocd-application-controller |  |
| argocd | argocd-application-controller-metrics | TCP/8082 → metrics |
| argocd | argocd-applicationset-controller | TCP/7000 → webhook |
| argocd | argocd-dex-server | TCP/5556 → http, TCP/5557 → grpc |
| argocd | argocd-redis | TCP/6379 → redis |
| argocd | argocd-repo-server | TCP/8081 → repo-server |
| argocd | argocd-repo-server-metrics | TCP/8084 → metrics |
| argocd | argocd-server | TCP/80 → 8080, TCP/443 → 8080 |
| argocd | argocd-server-metrics | TCP/8083 → metrics |
| bottleship | bottleship | TCP/80 → http |
| bottleship | oauth2-proxy | TCP/4180 → http |
| bottleship | oauth2-proxy-local | TCP/4180 → http |
| cat6-probe-8eeca0ea | server-0 | TCP/8080 → 8080 |
| cat6-probe-8eeca0ea | server-1 | TCP/8080 → 8080 |
| cat6-probe-8eeca0ea | server-2 | TCP/8080 → 8080 |
| cert-manager | cert-manager | TCP/9402 → 9402 |
| cert-manager | cert-manager-cainjector | TCP/9402 → 9402 |
| cert-manager | cert-manager-webhook | TCP/443 → https, TCP/9402 → http-metrics |
| cloudflared | cloudflared-metrics | TCP/2000 → metrics |
| coredns | coredns | UDP/53 → 53 |
| coredns | coredns-tailscale | UDP/53 → 53, TCP/53 → 53 |
| default | kubernetes | TCP/443 → 6443 |
| default | talos | TCP/50000 → 50000 |
| external-secrets | bitwarden-sdk-server | TCP/9998 → http |
| external-secrets | external-secrets-webhook | TCP/443 → webhook |
| garage | garage | TCP/3900 → s3-api, TCP/3902 → s3-web, TCP/3901 → rpc, TCP/3903 → admin |
| garage | garage-headless | TCP/3900 → s3-api, TCP/3902 → s3-web, TCP/3901 → rpc, TCP/3903 → admin |
| garage | garage-webui | TCP/3909 → http |
| goldpinger | goldpinger | TCP/8081 → 8080, UDP/6969 → 6969 |
| home-assistant | home-assistant | TCP/80 → http |
| home-assistant | matter-server | TCP/5580 → websocket |
| intel-device-plugins | inteldeviceplugins-controller-manager-metrics-service | TCP/8443 → https |
| intel-device-plugins | inteldeviceplugins-webhook-service | TCP/443 → 9443 |
| jellyfin | jellyfin | TCP/8096 → http |
| kube-state-metrics | kube-state-metrics | TCP/8080 → http, TCP/8081 → metrics |
| kube-system | kube-dns | UDP/53 → 53, TCP/53 → 53, TCP/9153 → 9153 |
| kube-system | metrics-server | TCP/443 → https |
| longhorn | longhorn-admission-webhook | TCP/9502 → admission-wh |
| longhorn | longhorn-backend | TCP/9500 → manager |
| longhorn | longhorn-frontend | TCP/80 → http |
| longhorn | longhorn-recovery-backend | TCP/9503 → recov-backend |
| metallb | frr-k8s-webhook-service | TCP/443 → webhook |
| metallb | metallb-webhook-service | TCP/443 → 9443 |
| mosquitto | mosquitto | TCP/1883 → 1883 |
| node-exporter | node-exporter-prometheus-node-exporter | TCP/9100 → 9100 |
| pocket-id | pocket-id | TCP/80 → http |
| signoz | chi-signoz-clickhouse-cluster-0-0 | TCP/9000 → 9000, TCP/8123 → 8123, TCP/9009 → 9009 |
| signoz | signoz | TCP/8080 → http, TCP/8085 → http-internal, TCP/4320 → opamp-internal |
| signoz | signoz-clickhouse | TCP/8123 → 8123, TCP/9000 → 9000 |
| signoz | signoz-clickhouse-operator-metrics | TCP/8888 → 8888 |
| signoz | signoz-k8s-infra-otel-agent | TCP/13133 → health-check, TCP/8888 → metrics, TCP/4317 → otlp, TCP/4318 → otlp-http |
| signoz | signoz-k8s-infra-otel-deployment | TCP/13133 → health-check |
| signoz | signoz-otel-collector | TCP/14250 → jaeger-grpc, TCP/14268 → jaeger-thrift, TCP/8081 → logsheroku, TCP/8082 → logsjson, TCP/8888 → metrics, TCP/4317 → otlp, TCP/4318 → otlp-http |
| signoz | signoz-zookeeper | TCP/2181 → client, TCP/2888 → follower, TCP/3888 → election |
| signoz | signoz-zookeeper-headless | TCP/2181 → client, TCP/2888 → follower, TCP/3888 → election |
| signoz | signoz-zookeeper-metrics | TCP/9141 → metrics |
| smartctl-exporter | smartctl-exporter-prometheus-smartctl-exporter | TCP/80 → http |
| tailscale | ts-coredns-tailscale-w79s7 |  |
| tailscale | ts-traefik-admin-k74lp |  |
| tailscale | ts-traefik-apps-tailscale-fdz98 |  |
| time-machine | time-machine | TCP/445 → 445, TCP/139 → 139 |
| traefik-admin | traefik-admin | TCP/443 → websecure |
| traefik-admin | traefik-admin-dashboard | TCP/8080 → traefik |
| traefik-admin | traefik-admin-metrics | TCP/9100 → metrics |
| traefik-apps | traefik-apps | TCP/80 → web, TCP/443 → websecure |
| traefik-apps | traefik-apps-dashboard | TCP/8080 → traefik |
| traefik-apps | traefik-apps-metrics | TCP/9100 → metrics |
| traefik-apps | traefik-apps-tailscale | TCP/8443 → edge, TCP/80 → web |
| tuppr | tuppr-metrics-service | TCP/8081 → metrics |
| tuppr | tuppr-webhook-service | TCP/443 → 9443 |
| volsync-system | volsync-metrics | TCP/8443 → 8443 |
| yak-shave | yak-shave | TCP/80 → http |

## Observed host/privilege exceptions (2026-11-07)

Grouped by namespace and container image to avoid treating generated pod names as stable selectors. Includes init containers. Network policy cannot be treated as containment against node compromise.

| Namespace | Component image | Exception |
|---|---|---|
| coredns | coredns/coredns:1.14.7 | capabilities: NET_BIND_SERVICE |
| home-assistant | 1activegeek/airconnect:1.12.4 | hostNetwork |
| home-assistant | ghcr.io/home-assistant/home-assistant:2026.11.0 | hostNetwork |
| home-assistant | ghcr.io/matter-js/python-matter-server:8.1.2 | hostNetwork |
| home-assistant | mikefarah/yq:4 | hostNetwork |
| kube-system | ghcr.io/bafulton/homelab-toolbox:1.0.4 | hostNetwork; capabilities: NET_ADMIN |
| kube-system | ghcr.io/siderolabs/flannel:0.28.9 | hostNetwork |
| kube-system | ghcr.io/siderolabs/flannel:0.28.9 | hostNetwork; capabilities: NET_ADMIN, NET_RAW |
| kube-system | registry.k8s.io/coredns/coredns:v1.14.7 | capabilities: NET_BIND_SERVICE |
| kube-system | registry.k8s.io/kube-apiserver:v1.37.2 | hostNetwork; capabilities: NET_BIND_SERVICE |
| kube-system | registry.k8s.io/kube-controller-manager:v1.37.2 | hostNetwork |
| kube-system | registry.k8s.io/kube-proxy:v1.37.2 | hostNetwork; privileged |
| kube-system | registry.k8s.io/kube-scheduler:v1.37.2 | hostNetwork |
| longhorn | docker.io/longhornio/csi-node-driver-registrar:v2.18.0 | privileged |
| longhorn | docker.io/longhornio/longhorn-engine:v1.13.0 | privileged |
| longhorn | docker.io/longhornio/longhorn-instance-manager:v1.13.0 | privileged |
| longhorn | docker.io/longhornio/longhorn-manager:v1.13.0 | privileged |
| longhorn | docker.io/longhornio/longhorn-manager:v1.13.0 | privileged; capabilities: SYS_ADMIN |
| longhorn | longhornio/longhorn-engine:v1.10.1 | privileged |
| mdns-advertiser | ghcr.io/bafulton/mdns-advertiser:1.0.2 | hostNetwork |
| metallb | quay.io/frrouting/frr:10.6.2 | hostNetwork |
| metallb | quay.io/frrouting/frr:10.6.2 | hostNetwork; capabilities: NET_ADMIN, NET_RAW, SYS_ADMIN, NET_BIND_SERVICE |
| metallb | quay.io/metallb/frr-k8s:v0.0.27 | hostNetwork |
| metallb | quay.io/metallb/frr-k8s:v0.0.27 | hostNetwork; capabilities: NET_RAW |
| metallb | quay.io/metallb/speaker:v0.16.2 | hostNetwork; capabilities: NET_RAW |
| node-exporter | quay.io/prometheus/node-exporter:v1.12.1 | hostNetwork; hostPID |
| smartctl-exporter | ghcr.io/joryirving/smartctl_exporter:0.15.0 | privileged |
| tailscale | tailscale/tailscale:v1.104.4 | privileged |
