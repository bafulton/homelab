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
