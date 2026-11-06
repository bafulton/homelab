# CAT-17 migration stages

This change is split into dependent PRs. Merge and verify each prerequisite before
advancing. No phase is a claim that CAT-17 acceptance criteria are complete.

1. **Explicit routing contract and legacy controller scope.** All current routes
   retain the existing Gateway/listeners and gain explicit access labels/parents.
   The shared chart temporarily permits legacy parents. The existing controller
   watches only its legacy-labeled GatewayClass and its exact Gateway. Verify its
   rollout is healthy before creating replacement GatewayClasses.
2. **Provision separate gateways and Tailscale permissions.** Add admin/apps
   controllers, unique proxy tags and administrator grants. The new apps LAN
   Service is initially ClusterIP so it cannot compete for `.200`. Keep all
   existing household/public/admin routes on legacy ingress. New app READMEs
   explain the target and remaining cutover work.
3. **Cut over traffic, enforce boundaries and retire legacy resources.** Move
   routes, populate DNS from observed proxy addresses, transfer `.200`, update
   Cloudflare/OCI upstreams, enforce admission, and retire old NodePorts/proxy.
   This phase requires a coordinated maintenance window with auto-sync paused;
   its PR supplies the detailed rollout/rollback runbook and adversarial tests.

The first phase does not restrict administrative LAN access. The existing
Tailscale policy and public upstreams are unchanged. Keep CRD ownership in
`traefik-crds` throughout. The temporary legacy route exception is removed only
in the final phase. OCI placement/locality and mixed-use app authorization remain
separate concerns under CAT-8/CAT-18/CAT-21.

## Stage 2 provisioning checks

Do not merge stage 2 until the legacy Deployment has rolled out its exact Gateway
scope and the legacy GatewayClass has `homelab.io/ingress=legacy`. The new
controllers must not be seen by an old unfiltered controller. Sync the legacy
policy update before the new admin Gateway; its original policy would reject
an `admin` listener. If auto-sync creates it first, retry the new app sync after
the legacy policy is updated; the old policy fails closed.

The two new Applications may auto-provision after stage 2 merges. Their own
dashboards use admin-class routes; existing application routes, `.200`, CoreDNS,
Cloudflare and OCI upstreams remain unchanged. The apps default Service is
ClusterIP, with a separate Tailscale LoadBalancer for `cluster-apps`. The admin
Service is Tailscale-only and exposes TCP 443. Verify generated Services allocate
no NodePorts, and each proxy carries only its dedicated role tag.

Wait for certificates Ready, Deployments Available and Gateway Programmed. Verify
administrator/edge grants via the policy PR workflow and live connectivity to the
new proxy using the dashboard hostname/assigned IP. Preserve application login.
Neither the new app READMEs nor this provisioning stage claim that old LAN admin
access has been removed; that is stage 3's cutover/retirement acceptance test.

Rollback before cutover: keep the existing controllers/routes, remove only the
new Applications' reviewed resources (they use `prune: false`), and revert stage
2's policy/grants if necessary. Do not remove shared CRDs or the existing ingress.
