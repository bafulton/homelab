# Container Images

Images built from this repo and published to GHCR by
[`.github/workflows/build-images.yaml`](../.github/workflows/build-images.yaml).

| Image | Contents | Used by |
|-------|----------|---------|
| `homelab-toolbox` | alpine + `curl`, `jq`, `git`, `kubectl` | node-health, signoz dashboard-sync, cluster-maintenance |
| `mdns-advertiser` | python + `zeroconf`, `kubernetes` + `advertiser.py` | mdns-advertiser |

## Why These Exist

These workloads used to run a generic base image and install their dependencies
at container start (`apk add curl jq`, `pip install zeroconf ...`). That makes
every pod boot depend on Alpine's CDN or PyPI being reachable, and resolves
versions at runtime where failures land in the cluster instead of in CI.

Both failure modes already happened:

- **node-health** died with `DNS: transient error` → `curl (no such package)`,
  silently stopping the thing that reports whether a node is alive.
- **mdns-advertiser** OOM-looped ~300 times after Renovate bumped its base image
  to `python:3.15-alpine`: PyYAML ships no cp315 musl wheel, so pip compiled it
  from source inside a 128Mi limit, taking every `.local` record down with it.

Baking the dependencies moves both classes of failure to build time, where a bad
bump fails a red CI check rather than production.

## Versioning

Each image directory holds a `VERSION` file. The workflow tags the build
`:<VERSION>` plus `:sha-<commit>`, and Renovate tracks the semver tag in the
consuming `values.yaml`. **Bump `VERSION` whenever you change a Dockerfile or
its scripts** — otherwise the new build overwrites an existing tag and nodes
with `imagePullPolicy: IfNotPresent` keep serving the cached layer.

Both images are built for `linux/amd64` and `linux/arm64` (beelink is amd64;
rpi5 and ocifree are arm64).

## Package Visibility

Both packages must be **public** in GHCR. New packages default to private even
from a public repo, so this is a manual step in each package's settings after
the first build; the symptom of missing it is `ImagePullBackOff` everywhere.

Public is the right default here: the repo is already public, so the images
disclose nothing new, and a private registry would need an `imagePullSecret` in
every consuming namespace. For core networking infra that means a pull
credential behind External Secrets behind the Bitwarden token — a cold-start
cycle where the advertiser can't pull its own image. Anonymous pulls have no
such ordering requirement, which also matters because rpi5 is re-provisioned by
reflashing its SD card.

Never bake a secret into these images, and never pass one as a build arg (they
persist in layers). Config belongs in ConfigMaps and Secrets at runtime.
