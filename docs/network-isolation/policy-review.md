# Existing policy review

Live collection on 2026-11-07 found **12 policies, all ingress-only**, confined to Argo CD and Longhorn. No egress restrictions exist in these objects. See `evidence/live-policies.yaml` and the fresh-render comparison for the exact selectors and rules. The review below identifies activation risks; it does not certify production traffic by observing flows.

| Policy (namespace) | Effective ingress allowance | Review / required action before activation |
|---|---|---|
| argocd-application-controller (argocd) | Named metrics port from any namespace | Scraping remains broad. Confirm named port resolves; later narrow to actual collector pods. |
| argocd-dex-server (argocd) | HTTP/gRPC from same-namespace argocd-server; metrics from any namespace | Check whether Dex is deployed/enabled and whether selectors match it. An unmatched policy is dormant, not missing coverage. |
| argocd-notifications-controller (argocd) | Metrics from any namespace | Check enabled component and named port; no egress restriction on notifications. |
| argocd-redis (argocd) | Named Redis port from server, repo-server, application-controller | Confirm every client including jobs/extensions; denies other namespaces once enforced. |
| argocd-repo-server (argocd) | Named RPC port from server, application-controller, notifications, ApplicationSet; metrics from any namespace | Validate all live selectors/named ports, repository reconciliation and webhook-triggered refresh. |
| argocd-server (argocd) | `ingress: [{}]`: all sources, all ports | No isolation for the server. Later replace broad allowance with admin gateway, public webhook path's gateway, and required internal callers. L4 policies cannot distinguish webhook HTTP paths. |
| backing-image-data-source (longhorn) | Manager, instance-manager, backing-image-manager/data-source in same namespace, all ports | Dynamic pods may be absent now. Exercise backing-image operations in rehearsal; do not prune rules solely because selectors currently match zero pods. |
| backing-image-manager (longhorn) | Same peers as above, all ports | Same dynamic coverage requirement. |
| instance-manager (longhorn) | Same peers as above, all ports; TCP/3260 from any source | Broad iSCSI rule is intentional storage reachability, not app isolation. Inventory node-originated iSCSI and verify mount/read/write across home/OCI. |
| longhorn-manager (longhorn) | Same-namespace manager, UI, CSI, recurring jobs, job-task pods, driver deployer; all ports | **Likely metrics gap:** SigNoz scraper is in `signoz`, while manager metrics use TCP/9500. Existing policy does not admit that cross-namespace caller. Confirm packet source and add a narrowly scoped allow before activation. |
| longhorn-recovery-backend (longhorn) | Same-namespace share-manager on TCP/9503 | Rehearse RWX/share-manager recovery and actual matching labels. |
| longhorn-webhook (longhorn) | TCP/9501 and 9502 from any source | Keep API-server admission/conversion working; review narrowing separately, accounting for node-originated traffic. |

## Review interpretation

- Namespace-omitted pod selectors select peers only in the policy's own namespace. `namespaceSelector: {}` permits pods across all namespaces. Rule entries and policy objects combine as a union.
- None of these policies protects unrelated namespaces or blocks LAN egress. Policies matching privileged Longhorn pods do not make those pods a host security boundary.
- Generated port/selector evidence is in [dependencies](dependencies.md). Dynamic Longhorn jobs and backing-image/share-manager pods require explicit runtime exercises.
- Audit the exact Argo-generated desired objects before activation. Fresh local renders are useful evidence but may differ due to capabilities, hooks, or live reconciliation.
- Before activation, resolve the metrics gap, check API/webhook/Redis/repo access, and test storage health, attachment, backups and restore. Any corrections belong in a separate production-policy PR.

## Live selector and named-port check

All current policy target selectors use matchLabels. The collected pod snapshot gives the following matches (dynamic resources can legitimately match zero pods). Peer selector validation and functional traffic checks are still required.

| Policy | Selected pods | Selected hostNetwork pods | Named ports resolved on selected pods |
|---|---|---|---|
| argocd/argocd-application-controller | 1 | 0 | {"metrics": [8082]} |
| argocd/argocd-dex-server | 1 | 0 | {"grpc": [5557], "http": [5556], "metrics": [5558]} |
| argocd/argocd-notifications-controller | 1 | 0 | {"metrics": [9001]} |
| argocd/argocd-redis | 1 | 0 | {"redis": [6379]} |
| argocd/argocd-repo-server | 1 | 0 | {"metrics": [8084], "repo-server": [8081]} |
| argocd/argocd-server | 1 | 0 | {} |
| longhorn/backing-image-data-source | 0 | 0 | {} |
| longhorn/backing-image-manager | 0 | 0 | {} |
| longhorn/instance-manager | 3 | 0 | {} |
| longhorn/longhorn-manager | 3 | 0 | {} |
| longhorn/longhorn-recovery-backend | 3 | 0 | {} |
| longhorn/longhorn-webhook | 3 | 0 | {} |

The completed 37-chart render found the same 12 policies as live. The three Argo raw differences are solely the API's default TCP protocol; no semantic spec differences were found after normalization. All named target ports resolved in the live snapshot, and no existing policy selected a hostNetwork pod. Policies for Longhorn backing-image components currently matched zero pods; their dynamic behavior still needs rehearsal. The recovery-backend and webhook selectors each match the same three manager pods as the manager policy. Their rules therefore combine: those manager pods also accept TCP/9501 and 9502 from all sources and TCP/9503 from share-managers. The union still does not allow cross-namespace metrics on TCP/9500. Review overlapping policy selectors as one effective allowance, rather than treating each policy as an independent component boundary.
