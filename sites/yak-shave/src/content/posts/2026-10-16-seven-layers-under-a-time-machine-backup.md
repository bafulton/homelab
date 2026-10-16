---
kind: shave
title: Seven layers under a failed Time Machine backup
date: "2026-10-16"
summary: macOS said the backup disk was unavailable. The disk was fine. Six layers down the actual cause was a dependency wheel that doesn't exist for Python 3.15.
descent:
  - The disk was fine
  - Nothing was advertising
  - 296 restarts
  - It builds itself on every boot
  - PyYAML has no wheel for 3.15
  - Nobody checked
  - It had already happened somewhere else
resolution: Dependencies are baked into a prebuilt image at build time, so a bad version bump fails a CI check instead of the cluster.
tags:
  - kubernetes
  - homelab
  - mdns
  - renovate
  - containers
public: true
---

My laptop had been refusing to back up for three days: *"try again later when the
disk is available."* The disk was available the whole time. Here is the descent.

Everything below is in my [homelab repo](https://github.com/bafulton/homelab); links go to the code at the commit
being discussed, since most of it has since been rewritten.

## The disk was fine

First instinct is to check the thing the error names. All of it was healthy:

| check | result |
| --- | --- |
| SMB server pod | `Running`, 20d uptime, 0 restarts |
| `nc 192.168.1.201 445` | **succeeded** |
| free space on the volume | 736 GB |

So the Mac could reach the server by IP. It just couldn't *find* it — because the
destination isn't an IP at all:

```console
$ tmutil destinationinfo
Name          : Family
Kind          : Network
URL           : smb://family@Time%20Machine._smb._tcp.local./Family
```

That's an mDNS name. Resolution is the dependency, not the disk.

## Nothing was advertising

```console
$ dns-sd -B _adisk._tcp local
Browsing for _adisk._tcp.local
DATE: ---Thu 15 Oct 2026---
22:06:19.636  ...STARTING...
(nothing)
```

Zero records, for `_smb._tcp` too.

> **Aside that cost me ten minutes.** `dns-sd` buffers its output when stdout
> isn't a terminal, so piping or capturing it prints *nothing at all* — which
> looks exactly like "no services found." Give it a pty:
> `script -q /dev/null timeout 5 dns-sd -B _adisk._tcp local`

## 296 restarts

My cluster runs one small advertiser pod that watches labelled ConfigMaps and
publishes them over Bonjour. `kubectl get pods` said `Running`. The container
status said otherwise:

```yaml
restartCount: 296
lastState:
  terminated:
    reason: OOMKilled
    startedAt:  02:15:54Z
    finishedAt: 02:16:16Z   # survived 22 seconds
resources:
  limits:  { memory: 128Mi }
```

Two tells worth stealing:

- **`kubectl exec` returned exit 137.** The cgroup sat so close to its ceiling
  that running `ps` was enough to trip the OOM killer. If exec gets killed,
  you're pinned at the limit.
- **Zero log lines. Ever.** Not truncated — empty. Log collection worked fine
  for every other pod on that node, so the container was dying *before* it
  produced output.

I raised the limit to 256Mi. It still died, in 22 seconds. Chasing a memory
limit upward is the wrong move when something else is the cause.

## It builds itself on every boot

The empty logs pointed at startup, and startup looked like this:

```sh
pip install --quiet zeroconf "kubernetes==35.0.0" pyyaml
python3 -u << 'PYTHON_SCRIPT'
...
```

A generic `python:3.x-alpine` base image, resolving its dependencies at
container start, inside a 128Mi cap. It never reached the Python. ([the whole
thing](https://github.com/bafulton/homelab/blob/7c486d0/kubernetes/infra/mdns-advertiser/templates/deployment.yaml#L26-L158)
— an 80-line heredoc embedded in a Kubernetes manifest, which is its own
problem.)

## PyYAML has no wheel for 3.15

The cluster is mixed amd64/arm64, and Alpine means musl. Checking PyPI for what
actually ships:

| package | cp314 musl/arm64 | cp315 musl/arm64 |
| --- | --- | --- |
| `zeroconf` | wheel | wheel |
| `kubernetes` | pure Python | pure Python |
| **`PyYAML` 6.0.3** | wheel | **none — wheels stop at cp314** |

No wheel means pip compiles it from source, at boot, in a 128Mi container. A
throwaway pod confirmed it:

```console
Building wheels for collected packages: pyyaml
  Building wheel for pyyaml (pyproject.toml): started
```

## Nobody checked

This is the part that actually matters.

| time (UTC, Oct 13) | event |
| --- | --- |
| 09:31 | last successful backup |
| 09:37:09 | Renovate merges *"update python docker tag to v3.15"* ([#474](https://github.com/bafulton/homelab/pull/474)) |
| 09:37:37 | advertiser pod recreated — **28 seconds later** |
| *3 days* | I notice my laptop hasn't backed up |

My [Renovate config](https://github.com/bafulton/homelab/blob/main/renovate.json#L80-L87) says:

```json
{ "matchUpdateTypes": ["minor", "patch"], "automerge": true }
```

`3.14 → 3.15` is a minor bump. It merged with no human review and nothing that
could have caught it — there was no build step to fail, because the image was
assembled at runtime, in production, on my LAN.

## It had already happened somewhere else

Grepping for the same shape turned up three more workloads installing packages
at container start. One of them had been quietly failing for 41 days:

```console
WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/APKINDEX.tar.gz: DNS: transient error
ERROR: unable to select packages:
  curl (no such package)
  jq (no such package)
```

That's [`node-health`](https://github.com/bafulton/homelab/blob/5d45a85/kubernetes/infra/node-health/templates/daemonset.yaml#L61) —
the DaemonSet whose entire job is to ping a healthcheck
service so I find out when a node dies. When it can't reach Alpine's CDN, it
can't install `curl`, so it can't tell me anything. 14 restarts across two
nodes.

## The fix

Two small images ([`images/`](https://github.com/bafulton/homelab/tree/main/images)) built in CI and published to
GHCR — free for public repositories, no egress charges, no `imagePullSecret` to
bootstrap. Dependencies are pinned and resolved at build time, on a runner with a
compiler and plenty of RAM.

PyYAML turned out to be unavoidable anyway: the Kubernetes client requires it
transitively. But a [builder stage](https://github.com/bafulton/homelab/blob/main/images/mdns-advertiser/Dockerfile#L15-L28)
compiles it once, at build time, and the final image ships neither the compiler
nor the build caches.

| | before | after |
| --- | --- | --- |
| memory | 126Mi against a 128Mi cap | **79Mi** |
| restarts | 296 | **0** |
| deps resolved | container start | image build |
| `.local` records on the LAN | 0 | 6 |
| failure lands in | my cluster | a red CI check |

A [guard in the workflow](https://github.com/bafulton/homelab/blob/main/.github/workflows/build-images.yaml#L41-L79)
fails the build if a Dockerfile changes without its `VERSION` bumping — otherwise the next Renovate bump would quietly republish the
same tag, and nodes with `imagePullPolicy: IfNotPresent` would keep serving a
stale cached layer while a freshly provisioned node pulled different bytes.

## What I'd keep

**Runtime dependency installation is a production dependency on a CDN.** Every
pod start becomes a network call that can fail, resolving versions where failure
lands in your cluster instead of your CI.

**Automerge is only as good as what it gates.** My config said *"automerge after
CI passes."* CI passed. CI just wasn't checking anything about this image.

**The symptom was five layers above the cause.** Time Machine was never broken,
the disk was never full, and the SMB server never went down. The honest fix was
a GitHub Actions workflow.

Three days of no backups, and the fix was a container registry. That's the yak,
shaved.
