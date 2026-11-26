# gameplane-crds

Owns Gameplane's CRDs (`*.gameplane.local`: GameServer, GameTemplate,
Module, ModuleSource, Backup, BackupSchedule, Restore, Cluster,
NetworkCapture) as an Argo CD Application of their own, apart from the
`gameplane` app.

## Why this exists

Up to 0.4.x the `gameplane` chart bundled its CRDs as a `gameplane-crds`
subchart. From 0.5.0 it doesn't: with `argoCD.enabled` (which the
`gameplane` app uses) it renders no CRDs at all, and requires "one external
CRD owner". Upstream publishes the same CRDs as their own chart,
`oci://ghcr.io/gameplanepanel/charts/gameplane-crds`; this app is that owner.

It also keeps the CRDs out of the `gameplane` app, so that app can prune.
Removing a CRD deletes every resource of its kind, and a `GameServer` owns
its world volume: if the `gameplane` app owned the CRDs, a stray prune could
delete every world.

## Ownership

- This app is the sole owner of the CRDs. The `gameplane` app sets
  `skipCrds: true`, so the two never both apply them.
- `prune: false` here, so a change in Git can't remove a CRD.
- `serverSideApply: true` is required: the GameServer and GameTemplate CRDs
  exceed the client-side last-applied annotation size limit.

## Upgrades

Keep this chart at the same version as the `gameplane` chart: the operator
expects the CRDs of its own release. Renovate bumps both in one PR (the
`gameplane` group in `renovate.json`), never automerged. Roll the operator
back only together with its CRDs: from 0.5.0, an older operator can't update
scheduled Backups under the newer Backup CRD.
