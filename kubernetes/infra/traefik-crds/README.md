# traefik-crds

Owns the **Traefik** and **Gateway API** CRDs as a standalone ArgoCD
Application, decoupled from the Traefik controller's release cycle.

## Why this exists

The Traefik Helm chart bundled its CRDs (both `traefik.io` and the Gateway API
standard channel) through v39. As of chart **v40** it ships **no CRDs at all**
(see the [upstream note][traefik-v40]). Without a dedicated owner, upgrading the
controller would leave the CRDs unmanaged — and because the `traefik`
Application syncs with pruning, an orphaned Gateway API CRD would cascade-delete
every `Gateway` and `HTTPRoute` in the cluster, taking down all ingress routing.

This app uses Traefik's official companion chart, `traefik/traefik-crds`, with
both CRD sets enabled — the pattern Traefik recommends for v40+.

## What's included

- `traefik: true` — the `traefik.io` CRDs (IngressRoute, Middleware,
  TraefikService, …). Unused today (the homelab routes via Gateway API), kept for
  parity with what the main chart used to ship.
- `gatewayAPI: true` — the Gateway API **standard-channel** CRDs. Chart `1.18.0`
  ships bundle **v1.5.1** (an upgrade from the v1.4.0 the Traefik v39 chart
  shipped; adds the now-GA `listenersets` and `tlsroutes`). Backward-compatible:
  existing standard-channel resources remain valid.
- `hub: true` — the `hub.traefik.io` CRDs. Unused (Traefik Hub is disabled), but
  the v39 main chart shipped them, so adopting them keeps the `traefik` app from
  flagging 14 now-orphaned CRDs as `requiresPruning`. One v39 CRD
  (`apiaccesses.hub.traefik.io`) isn't in chart 1.18.0 and stays orphaned —
  unused, harmless, deletable by hand if desired.

## Ownership handoff (v39 → v41)

When migrating the controller to v41, this app must own the CRDs *before* the
`traefik` app drops them. Two safeguards handle the race:

1. `syncWave: "-2"` — this app applies before the Traefik controller.
2. `prune: false` on **both** this app and the `traefik` app — even if the
   controller syncs first, the CRDs are never deleted; this app then adopts them
   via server-side apply.

`serverSideApply: true` is required — the Gateway API CRDs exceed the
client-side last-applied annotation size limit.

[traefik-v40]: https://github.com/traefik/traefik-helm-chart/releases/tag/v40.0.0
