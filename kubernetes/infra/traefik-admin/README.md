# Administrative ingress

Dedicated Traefik controller for wholly administrative interfaces. This is a
shared gateway: individual dashboards do not become separate Tailscale machines.
The operator exposes one proxy, `cluster-admin.catfish-mountain.ts.net`, tagged
only `tag:k8s-admin`. `group:homelab-admins` may reach its TCP port 443.

## Traffic and routes

```text
Administrator's Tailscale device
  -> cluster-admin:443
  -> traefik-admin / Gateway traefik-admin / listener admin
  -> ClusterIP backend
```

CoreDNS maps these administrative service names to the shared proxy:

- `argocd.catfish-mountain.com`
- `longhorn.catfish-mountain.com`
- `garage.catfish-mountain.com`
- `signoz.catfish-mountain.com`
- `goldpinger.catfish-mountain.com`
- `traefik-apps.catfish-mountain.com` — apps controller dashboard
- `traefik-admin.catfish-mountain.com` — this controller's dashboard

The only `*.catfish-mountain.ts.net` name here is the shared proxy's
`cluster-admin.catfish-mountain.ts.net` identity. The dashboard Services use port
8080 inside the cluster and are not published on the proxy. Existing application
login/authorization remains in place; the gateway does not grant an application
session.

## Isolation

- The only externally exposed Service is a Tailscale-class LoadBalancer on 443,
  with `allocateLoadBalancerNodePorts: false`. Metrics and dashboard Services
  are ClusterIP. There is no LAN VIP, NodePort, host port, or host networking.
- Gateway provider scope is exactly `traefik-admin` in namespace `traefik-admin`,
  with GatewayClass label selector `homelab.io/ingress=admin`.
- Kubernetes Ingress and Traefik CRD providers are disabled. The Gateway is
  explicitly templated to avoid inheriting the upstream default HTTP listener.
- Administrative routes declare `access: admin`; the shared chart generates
  explicit admin Gateway/listener references.
  Admission rejects mismatched route attachments and alternate external exposure.
- The wildcard certificate is issued in this namespace by the existing
  `letsencrypt-production` ClusterIssuer. The apps instance has a separate copy.
- `skipCrds: true` leaves the single CRD owner, `traefik-crds`, unchanged.

Tailscale policy is in [policy.hujson](../../../tailscale/policy.hujson).
Do not add the broadly used `tag:k8s` to this proxy. The operator can assign this
tag, but is not itself granted access to the administrative frontend.

This isolates ingress from ordinary LAN/public clients. Cluster-internal access
and Kubernetes administrators' ability to port-forward are separate trust paths;
Broader workload NetworkPolicy enforcement is separate. Home Assistant, Jellyfin and Pocket ID
remain on apps ingress with application authentication; their administration is
not claimed to be network-isolated by this change.

## Verification

```sh
kubectl -n traefik-admin get deployment,svc,gateway,httproute,certificate
kubectl get gatewayclass traefik-admin
kubectl -n tailscale get pods
```

The wildcard Certificate should be Ready and the Gateway Programmed. The
`tag:k8s-admin` grant in the Tailscale policy is limited to
`group:homelab-admins` on TCP 443; ungrouped tailnet members have no grant to this
proxy. The apps Gateway, LAN VIP, public tunnel and OCI edge do not route admin
hostnames to this controller.

Refresh dependencies with `helm dependency update` before rendering. First render with `--include-crds` to inspect bundled CRDs. To mirror Argo
with `skipCrds: true`, omit `--include-crds`; adding `--skip-crds` alongside
`--include-crds` does not suppress them in Helm template.
