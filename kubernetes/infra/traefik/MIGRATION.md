# CAT-17 ingress migration

This is stage 3 of the dependent PR stack: [routing preparation #581](https://github.com/bafulton/homelab/pull/581),
[replacement gateways #583](https://github.com/bafulton/homelab/pull/583), then this
cutover/retirement PR. Merge and verify the earlier stages first.

This branch is a coordinated target configuration, **not a safe unattended merge**.
Argo auto-syncs `main`; the Tailscale policy also applies on pushes to `main`.
Prepare the maintenance window and pause affected reconciliation before merging.
No rollout is implied by successful Helm/CEL tests. ApplicationSet sync waves do
not provide cross-Application ordering.

## Inventory and preserved boundaries

| Class | Services / interfaces | Target |
| --- | --- | --- |
| Administrative | Argo UI/API, Longhorn UI, Garage UI, SigNoz UI, Goldpinger UI, both Traefik dashboards | shared `cluster-admin`, TCP 443, `tag:k8s-admin` |
| Mixed-use | Home Assistant, Jellyfin, Pocket ID | apps ingress; existing application roles/authentication |
| Public | BottleShip, yak-shave, household public names, OIDC, Argo webhook | apps ingress; existing intended transports |
| Household non-HTTP | MQTT `.202`, Time Machine `.201`, discovery/Matter | preserved |
| Internal | Garage S3/admin API, ClickHouse, Redis, collectors, metrics, webhooks | ClusterIP/internal traffic; no new admin routes |
| Recovery exception | credential-protected Talos/Kubernetes node APIs | preserve local access; CAT-19/CAT-20 cover recovery verification |

Read-only live inventory on 2026-11-05 confirmed the six original admin backends
are ClusterIP Services. The old LAN gateway uses NodePorts 31642/31789 and the old
Tailscale gateway uses 32369/31461/31703. These must disappear at retirement;
blocking only `.200` is insufficient. Inventory again immediately before rollout.

Home Assistant uses host networking/8123, Matter Server uses 5580. Other observed
host ports belong to node-exporter, MetalLB, and OTel agent health/metrics/ingestion.
They are not additional admin dashboards. Preserve household endpoints, and record
those telemetry surfaces for CAT-6 rather than claiming ingress grants isolate
all node ports. Kubernetes/Talos APIs remain intentional credential-protected
local exceptions. No arbitrary LAN route to pod/Service CIDRs is authorized by
this design; audit local router routes and IPv6 as well as Kubernetes objects.

## Before merge

1. Confirm a working credential-protected local Kubernetes/Talos connection, and
   maintain it throughout. Follow existing recovery documentation; do not reboot
   nodes. Confirm `fulton.benjamin@gmail.com` is the exact tailnet login. Review the
   policy PR tests, including an actual nonadministrator user if one exists.
2. Save the current commit SHA and manifests for affected Applications, both
   ApplicationSets, legacy Traefik Deployment/Services/Gateway/GatewayClass,
   HTTPRoutes and admission policies. Save the **current** generated edge dynamic
   configuration on the VM. Do not export Kubernetes Secrets into the repository.
3. Suspend reconciliation so ApplicationSet cannot restore auto-sync settings:
   first disable automated sync on the `applications` root Application and
   `argocd` Application, then scale `argocd-applicationset-controller` to zero.
   Disable automated sync on the existing affected Applications: `traefik`,
   `argocd`, `coredns`, `longhorn`, `garage`, `signoz`, `goldpinger`, `pocket-id`,
   `home-assistant`, `jellyfin`, `bottleship`, `yak-shave`, `traefik-admin`,
   `traefik-apps`. Save the original
   settings/replica count for restoration. A patch to disable automation is:

   ```sh
   kubectl -n argocd patch application APPLICATION --type=merge \
     -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
   ```

   Verify that no sync is already in progress. Keep ApplicationSet stopped until
   the migration is complete; newly discovered Applications would otherwise auto-sync.
4. Verify stage 1's legacy controller scope is deployed: GatewayClass `traefik`
   has `homelab.io/ingress=legacy`, and the legacy Deployment's Gateway provider
   specifies that label selector plus exact Gateway `traefik/traefik`. Stage 2
   must already have provisioned both new proxies/certificates, with the apps
   default Service still ClusterIP. Do not proceed with an unfiltered legacy
   controller or unavailable replacement gateway.
5. Before merging, generate DNS values from the provisioned stage-2 proxies
   with `./scripts/update-ingress-dns.py`, review their actual addresses/tags,
   and push that values change to this cutover PR. Run the helper with `--check`
   immediately before syncing DNS to detect proxy recreation. This draft keeps
   the old zone until real replacement addresses exist; do not merge with stale
   DNS values. All repository changes go through this PR or a follow-up PR.
6. Merge only after these preparations. Confirm stage 2's Tailscale policy
   workflow succeeded and its grants are live. The old `tag:k8s` gateway remains
   reachable by the administrator during the transition.

## Build the replacement entrances

1. Manually sync the legacy `traefik` Application to install its new admission
   policies. Its old deployment is not pruned because `prune: false` remains.
   Do not run a broad prune against this Application. Check policy
   `status.typeChecking.expressionWarnings` is empty before proceeding. The strict
   Gateway policy replaces stage 2's temporary legacy/listener-name allowances.
2. Verify the existing new Argo Applications still use their matching paths and
   namespaces, `source.helm.skipCrds: true`, and `CreateNamespace=true`. Keep
   automated sync disabled during cutover. Both replacement Applications were
   created by stage 2; do not create duplicate Helm owners.
3. **Do not sync `traefik-apps` to stage 3 yet.** Leave its running stage-2 default
   Service as ClusterIP until the VIP handoff. Its Tailscale Service, Gateway,
   dashboard route and certificates are already provisioned. Confirm there are
   no temporary Helm parameters left from earlier experiments.
4. Require both new Deployments Available and all referenced Certificates Ready;
   require Gateways Programmed. Verify `cluster-admin` has **only** `tag:k8s-admin`
   and `cluster-apps` has **only** `tag:k8s-apps`. Never give admin ingress
   `tag:k8s`. Inspect generated Services/pods for NodePorts, host ports and host
   networking. Sync admin ingress if needed; defer apps ingress until handoff.
5. Verify administrator access to `traefik-admin.catfish-mountain.com` using the
   new proxy IP and correct SNI/Host before changing DNS. The apps controller's
   dashboard uses an admin route too. The admin proxy exposes only TCP 443;
   metrics/dashboard backend ports remain ClusterIP.

## Migrate routes and upstreams

This is a maintenance window: moving an HTTPRoute's parents removes it from the
legacy controller immediately. Do not expect duplicate routes or zero downtime.

1. Sync Goldpinger first, then Garage, Longhorn, SigNoz, and finally Argo CD. Check
   each route Accepted/ResolvedRefs on `traefik-admin`. Keep local kubectl access
   while moving Argo's UI. Its public webhook is separately attached to apps.
2. Sync the household/public route Applications. BottleShip's Middleware now has
   the apps provider label and ingress class; verify it resolves and continues to
   enforce authentication. Require every route's explicit parent/listener and
   access label. No administrative backend may remain on a legacy/apps route.
3. Run `./scripts/update-ingress-dns.py --check`, then sync CoreDNS using the
   values reviewed in this PR before merge. Explicit admin A records target the
   admin proxy, and the zone apex/wildcard target apps. If the check detects
   changed proxy addresses, stop and update DNS through a follow-up PR before
   syncing. Do not invent addresses or use CNAMEs into MagicDNS: client handling
   is not portable ([upstream issue](https://github.com/tailscale/tailscale/issues/7650)).
   Repeat the helper whenever either proxy identity is recreated. Verify DNS on
   real clients before retiring the legacy gateway.
4. Transfer the LAN VIP: delete **only** old Service `traefik/traefik` after saving
   it, then sync `traefik-apps` to stage 3, which changes its default Service
   from ClusterIP to LoadBalancer without NodePorts. Wait until its LAN Service owns `192.168.1.200`. Existing
   `.local` ConfigMaps and mDNS advertisements continue using that address.
5. In `opentofu/cloudflare`, load credentials with the existing `env.sh`, review
   `tofu plan`, and apply the tunnel's new upstream
   `traefik-apps.traefik-apps.svc.cluster.local:80`. Preserve existing hostname
   allowlists and webhook exception. Do not include unrelated state changes.
6. Switch the running OCI forwarder's upstream to
   `cluster-apps.catfish-mountain.ts.net:8443`. The changed module default applies
   only on future provisioning: cloud-init does not rerun and `user_data` is
   ignored. For this migration, back up `/etc/traefik/dynamic.yml`, replace only
   its existing `cluster-gateway...:8443` upstream with the new name, and verify
   Traefik's watched-file reload (restart the edge Traefik if required). Preserve
   SNI allowlists/canary configuration. A full VM rebuild is optional and has
   additional public-IP/DNS consequences documented in the OCI README.

## Retire the legacy ingress

Do this before declaring CAT-17 enforced. The old `traefik-dashboard` HTTPRoute
and backend Service are no longer desired but remain because pruning is disabled.

1. Inventory all remaining references to Gateway `traefik/traefik`. Remove the
   old `traefik-dashboard` HTTPRoute; there must be no other legacy parent refs.
2. Scale legacy Deployment `traefik/traefik` to zero, then delete the saved,
   reviewed legacy resources: Deployment, `traefik`, `traefik-tailscale`,
   `traefik-dashboard`, and `traefik-metrics` Services, Gateway `traefik`,
   GatewayClass `traefik`, old IngressClass, ServiceAccount/RBAC/PDB and legacy
   certificates after confirming the new certificates are Ready. Review exact
   names from the saved inventory; do not delete resources by a broad `traefik`
   label. **Keep** the legacy Argo Application and its admission policies, and
   keep `traefik-crds`. Do not delete namespaces or CRDs.
3. Confirm the operator removes the old proxy and all old gateway NodePorts are
   gone from Services. Remove temporary legacy `tag:k8s:8443` edge permission
   from the policy in a follow-up reviewed commit; `tag:k8s` remains on CoreDNS.
4. Restore ApplicationSet controller replicas, root/Argo auto-sync and affected
   Applications' original automation settings. Refresh the ApplicationSets and
   confirm they preserve `skipCrds: true`, desired values and policy ownership.
   Remove any remaining temporary Helm parameters.

## Required acceptance matrix

Record results for an authorized administrator, an actual nonadministrator
Tailscale user, an ordinary LAN client with Tailscale disabled, and an external
client. An HTTP login page/401 from an admin backend is still network reachability
and therefore fails a denied-path test.

- Administrator can reach all seven dashboard names, with existing application
  authentication retained. Nonadministrator and `tag:edge` cannot reach admin 443.
- LAN `.200`, node LAN/Tailscale IPs, old NodePorts, known backend/Service/pod
  addresses, IPv6, and supplied correct Host/SNI do not expose admin interfaces.
  Inspect local routing rather than assuming ClusterIP means unreachable.
- Cloudflare and OCI paths cannot reach admin names, including public SNI with
  admin Host, wildcard names and spoofed forwarding headers. The OCI exposure
  canary remains healthy.
- HA LAN/public control and discovery/Matter, Jellyfin playback/seek/native apps,
  Pocket ID OIDC/passkeys, BottleShip callbacks, yak-shave, MQTT/SMB, backups,
  telemetry and real GitHub webhook delivery continue working.
- Admission rejects admin routes on apps/legacy parents, missing classification
  or listener, webhook catchalls, LAN/NodePort admin Services, and host-network
  admin pods. Policies report no type warnings. Run the local CEL regression suite.

Do not mark the issue complete without these live results. CAT-6 workload
isolation and CAT-8/CAT-18 household locality/availability remain separate work.

## Rollback

Keep reconciliation paused. Use the saved revision/manifests; do not reset the
whole repository or alter unrelated user work.

1. Restore the former admission policy/binding definitions first so legacy route
   and Gateway manifests are accepted again. Remove only the new boundary
   bindings if they block restoration; keep saved definitions for reapplication.
2. Remove/revert apps ingress's ownership of `.200` before recreating the saved
   legacy LAN Service. Restore the legacy Deployment, Gateway/Class, Services,
   certificates/references and original provider scope. Wait for it to be Ready.
3. Point affected Argo Applications at the saved revision and sync original routes,
   Middleware and CoreDNS values. Restore Cloudflare's original upstream and the
   saved OCI dynamic configuration. Check household/public/admin access.
4. Keep the new Tailscale policy if administrator recovery still works; restore
   the saved policy through GitOps only if required. Policy rollback may reopen
   the previous broad access, so record that CAT-17 is no longer enforced.
5. Once recovery is verified, disable/remove only the replacement ingress
   resources and restore original reconciliation settings. Preserve the saved
   artifacts until the rollout is accepted.
