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

This app uses Traefik's official companion chart, `traefik/traefik-crds`, the
pattern Traefik recommends for v40+.

## What's included

- `traefik: true` — the `traefik.io` CRDs (IngressRoute, Middleware,
  TraefikService, …). Unused today (the homelab routes via Gateway API), kept for
  parity with what the main chart used to ship (they're core Traefik CRDs, cheap
  to keep, plausibly useful later e.g. Middleware).
- `gatewayAPI: true` — the Gateway API **standard-channel** CRDs. Chart `1.18.0`
  ships bundle **v1.5.1** (an upgrade from the v1.4.0 the Traefik v39 chart
  shipped; adds the now-GA `listenersets` and `tlsroutes`). Backward-compatible:
  existing standard-channel resources remain valid.

## Excluded: `hub.traefik.io` CRDs (`hub: false`)

Traefik Hub is a commercial add-on we don't use (Hub disabled, 0 Hub CRs). The
main chart still ships 15 `hub.traefik.io` CRDs in its `crds/` directory; we
don't carry that cruft forward.

Deleting them only sticks once the `traefik` app stops rendering them. v41 did
**not** stop shipping CRDs - only the `templates/` copies went away, and
`crds/` is still there - so until `skipCrds: true` was set on that app it
re-applied all 15 on its next sync, and a hand-deletion would reappear within
minutes. With `skipCrds` in place nothing declares them, `prune: false` means
ArgoCD won't touch them either, so they can be removed once by hand (safe: no
CRs exist):

```bash
kubectl get crd -o name | grep hub.traefik.io | xargs kubectl delete
```

## Ownership handoff (v39 → v41)

When migrating the controller to v41, this app must own the CRDs without the
`traefik` app deleting them as it stops rendering them. The guarantee is
**`prune: false` on both apps**: the two Applications self-sync independently and
in no fixed order (sync waves don't gate ApplicationSet-generated apps), so
ordering can't be relied on — but with pruning off, the existing CRDs are never
deleted regardless of which app syncs first, and this app adopts them via
server-side apply.

`serverSideApply: true` is required — the Gateway API CRDs exceed the
client-side last-applied annotation size limit.

[traefik-v40]: https://github.com/traefik/traefik-helm-chart/releases/tag/v40.0.0
