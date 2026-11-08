# CAT-6 workload isolation preflight

This is preparation for [CAT-6](https://linear.app/catfish-mountain/issue/CAT-6/enforce-workload-isolation-with-network-policies), not an enforcement rollout. No production policies, Talos configuration, or Argo reconciliation settings change in this PR. Test fixtures are outside `kubernetes/`, so ApplicationSets cannot discover them.

## Agreed scope for this homelab

The first rollout is complete when ordinary public application pods cannot reach unrelated services, administrative endpoints, or LAN devices, while required application traffic still works. Keep the inventory as reference; it is not a checklist that must be exhausted.

Before activation: resolve existing-policy gaps, verify the bundled engine version and relevant fixes, and prepare a concrete recovery procedure using working local administrative access. After activation: use the existing three-node harness to demonstrate allowed and denied pod/Service traffic, then restrict public apps incrementally and check DNS, sign-in, gateways, media, monitoring, storage, and a scheduled backup. Exercise policy removal to confirm recovery.

Home Assistant, host-networked workloads, privileged infrastructure, and existing storage/system policy allowances remain explicitly trusted exceptions initially. New comprehensive isolation for identity/admin/storage namespaces, exhaustive device and dynamic storage mapping, a separate replica of the homelab, agent crash/fail-open analysis, performance benchmarks, and a full engine-removal rehearsal are deferred unless a concrete failure makes them necessary. Keep the version-specific engine recovery instructions and never flush shared firewall rules.

## Decision and activation gate

First evaluate Talos-managed Flannel + kube-network-policies. Retain kube-proxy, MetalLB, home-node Flannel/LAN paths, and home↔OCI Tailscale subnet routing with original pod source addresses. Cilium remains the alternative if this implementation fails correctness, resource, or operational checks. A CNI migration needs a separate reviewed plan.

Talos 1.13 introduced `cluster.network.cni.flannel.kubeNetworkPoliciesEnabled`; the repository and live nodes use Talos 1.14.5 with the 1.13 config layout. Applying that field alone does not update an existing bootstrap deployment: bootstrap manifests must also be synchronized. Do not execute activation as part of this preflight.

Before activation, identify the exact policy image produced by the installed Talos version and verify its fixes and runtime requirements. Upstream [hostNetwork address-set bug #380](https://github.com/kubernetes-sigs/kube-network-policies/issues/380) is closed via a linked fix; confirm the deployed image contains it. Also check the linked same-node Service reply issue #379. A closed issue is not evidence that the bundled image is fixed. Use the existing connection matrix and essential-service checks to catch API, NAT reply, and cross-node regressions. Investigate resource use or engine failure behavior if observed problems warrant it; these are not separate research prerequisites.

Sources: [Talos integration announcement](https://github.com/siderolabs/talos/discussions/12998), [Flannel integration](https://github.com/flannel-io/flannel/blob/master/Documentation/netpol.md), [policy engine](https://github.com/kubernetes-sigs/kube-network-policies), [Kubernetes semantics](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

## Evidence and collection

See [policy review](policy-review.md), [dependency matrix](dependencies.md), and [validation results](validation.md). `evidence/` contains sanitized policy specifications and fresh chart coverage. Live data is a point-in-time observation, not a guarantee of future placement or traffic.

Recollect from the repository root (Python 3 + PyYAML, Helm, kubectl):

```sh
python3 scripts/network-isolation/audit.py --context homelab --output /tmp/cat6-audit-new
```

The collector reads nodes, pods, Services, EndpointSlices, and NetworkPolicies. It exports no Secrets, pod environment variables, ConfigMaps, or whole chart renders. Treat the output as internal infrastructure metadata. It copies charts to a temporary directory, discards stale tarballs, refreshes dependencies, and renders every app with `--include-crds`, the ApplicationSet release name/namespace, and Kubernetes 1.37.2 capabilities. Existing locks and vendored files in the checkout are untouched. Helm and live collection failures stop the audit; a partial output directory is not a completed audit. CRD API capability differences and Argo-specific rendering still require comparison with Argo's generated manifests before activation.

## Progressive rollout

1. Resolve existing policy gaps that would break required traffic when enforcement becomes active, especially Longhorn metrics. Verify the engine image and relevant fixes. Audit existing policies together because activation affects all of them.
2. Confirm working local kubectl/talosctl access and save the pre-change config/resources securely. Write the version-specific recovery commands before the maintenance window. A separate disposable cluster is optional.
3. Activate enforcement in a maintenance window. Run the three-node allowed/denied matrix and check API, DNS, gateways, telemetry, and storage. Recover immediately if required connectivity breaks.
4. Start with yak-shave, then BottleShip/Jellyfin. Add ingress and egress restrictions incrementally, allowing DNS, the gateway, monitoring, backup movers, and each app's required integrations. Prove that unrelated service, admin and LAN connections fail, including alternate gateway paths where relevant.
5. Check fresh sign-in, media/WebSockets, monitoring, storage operations and the next scheduled backup. Test policy removal and restored connectivity. Document trusted exceptions and stop once these boundaries work; expand coverage only for a demonstrated need.

Policies are additive: no new restrictive policy can override a broad allow. Use namespace + pod selectors together for specific cross-namespace callers. Match destination container ports, not just Service ports. Standard NetworkPolicy does not provide hostname-based Internet allowlists, HTTP authorization, or dependable host process isolation. RBAC/admission must also prevent ordinary workloads from changing trusted labels, policies, or launching host-network/privileged pods.

## Test harness

```sh
# Creates nine disposable pods and three Services, checks connectivity, deletes its namespace.
python3 scripts/network-isolation/check.py --context homelab \
  --nodes beelink rpi5 ocifree --output /tmp/cat6-baseline-new.json

# Run after reviewed engine activation (a rehearsal cluster is optional).
# Adds only test-namespace policies; does not install/enable an engine.
python3 scripts/network-isolation/check.py --context homelab \
  --nodes beelink rpi5 ocifree --enforce --output /tmp/cat6-enforcement-new.json
```

Each node hosts an HTTP server and two clients. Every source/destination pair is checked via direct pod IP and a single-endpoint ClusterIP Service (including DNS resolution). DNS itself is checked over TCP and UDP. Baseline must pass before policy results are accepted. Ingress-only policy permits one client role and denies the other; after removing it the open matrix is rerun. Egress-only policy restricts the denied client to DNS; the allowed client is the reachability control. Removing that policy must restore the open matrix. Connections are fresh TCP connections, not reused sessions. `--settle` is a convergence allowance, not a measured convergence guarantee.

The harness exits nonzero on an unexpected allow, broken allowed path, DNS failure, exec error, or cleanup failure. Results persist even on exceptions. A refusal or timeout counts as denied only when kubectl exec itself succeeds; baseline and allowed controls establish server reachability. Readiness checks use kubelet/node traffic, so they are not substitutes for client controls. The image is multi-architecture; pin a tested manifest digest before the activation rehearsal. If interrupted with SIGKILL, inspect the recorded/generated namespace name and delete only that `cat6-probe-*` namespace after verifying its `homelab.io/purpose=cat6-probe` label.

This harness establishes synthetic L3/L4 policy behavior. It does not yet establish production isolation, LAN/tailnet egress denial, storage correctness, or resilience during WAN loss. The dependency matrix lists the remaining real-workload checks. No CAT-6 acceptance criterion should be closed solely on the current baseline results.

## Rollback runbook

**Policy rollback (application batch):** prepare a named list of changed objects and a sanitized pre-change policy snapshot. For GitOps-owned policies, set `syncPolicy.autoSync: false` in the owning wrapper's values, allow the ApplicationSet to reconcile it, and verify `spec.syncPolicy.automated.enabled=false` on the generated Application before manual recovery. A direct Application patch can be overwritten by the ApplicationSet. If GitOps is unavailable, use the verified local recovery path and account explicitly for its controllers. Delete only the newly introduced policies and restore only the modified policies from the snapshot. `kubectl apply` alone will not delete added policies. Verify allowed paths and expected restored connectivity with fresh connections; then make Git match the intended state before resuming sync.

**Harness rollback:** `--enforce` removes the ingress policy, rechecks connectivity, independently tests egress, removes that policy, and checks connectivity again. `finally` deletes the dedicated namespace even when the matrix fails. See validation results for what was actually exercised.

**Engine rollback:** revert the Talos enablement field using the saved config and synchronize bootstrap manifests using the version-matched Talos procedure. Check whether the policy container and its kernel hooks/rules are removed on every node. Merely stopping the container is insufficient evidence of cleanup. Never flush all iptables/nftables rules: kube-proxy and Tailscale own rules too. Write the version-specific recovery steps before activation; they are deliberately not automated here. A full engine-removal rehearsal is deferred unless needed to establish a workable recovery path. If a node restart proves necessary, use `talos/scripts/safe-reboot-node.sh` with Longhorn safeguards. A workable recovery procedure is an activation requirement; exhaustive engine failure and removal testing is outside the initial homelab scope.
