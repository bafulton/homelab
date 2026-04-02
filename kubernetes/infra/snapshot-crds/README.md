# snapshot-crds

Installs the VolumeSnapshot CRDs via the [wiremind/snapshot-controller-crds](https://github.com/wiremind/wiremind-helm-charts/tree/main/charts/snapshot-controller-crds) Helm chart.

## CRDs installed

| CRD | Short names |
|-----|-------------|
| `volumesnapshots.snapshot.storage.k8s.io` | `vs` |
| `volumesnapshotcontents.snapshot.storage.k8s.io` | `vsc`, `vscs` |
| `volumesnapshotclasses.snapshot.storage.k8s.io` | `vsclass`, `vsclasses` |
| `volumegroupsnapshots.groupsnapshot.storage.k8s.io` | |
| `volumegroupsnapshotcontents.groupsnapshot.storage.k8s.io` | |
| `volumegroupsnapshotclasses.groupsnapshot.storage.k8s.io` | |

## Current consumers

| Component | Why |
|-----------|-----|
| [volsync](../volsync) | Controller watches for VolumeSnapshot resources on startup, even with `copyMethod: Direct` |
