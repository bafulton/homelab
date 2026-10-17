# Yak Shave

The blog at [yak-shave.com](https://yak-shave.com) — a static site served by Caddy. Two stateless replicas, no volumes, nothing to back up.

The site itself — posts, design, frontmatter schema, local development — lives in [`sites/yak-shave/`](../../../sites/yak-shave/README.md). This chart only covers how it runs in the cluster.

## Access

| Method | URL | Notes |
|--------|-----|-------|
| Public | `https://yak-shave.com` | Via Cloudflare Tunnel → Traefik |
| Public | `https://www.yak-shave.com` | 301s to the apex |

No LAN or Tailscale route, and no mDNS: it is a public site with nothing private to reach.

`/` 302s (never 301) to the newest post's own URL, so every fragment link on the front page keeps working when a newer post takes its place. The redirect target is generated at build time into `/etc/caddy/latest.caddy`.

## Publishing

Publishing a post is one push to `main`. Nothing in this directory is edited by hand.

```
push to main (sites/yak-shave/**)
  └─ .github/workflows/build-site.yaml
       ├─ npm ci && npm run build        content schema fails the build here
       ├─ docker buildx → ghcr.io/bafulton/yak-shave:sha-<commit>
       └─ sed the tag into values.yaml, commit, push
            └─ ArgoCD syncs the new tag
```

The tag is immutable per commit, so there is no tag to overwrite and no `VERSION` to bump — the stale-layer failure that the `images/` guard exists to prevent cannot happen here. Renovate deliberately does not track `image.tag`; it does track the Caddy base image in `sites/yak-shave/Dockerfile` and the npm dependencies.

The write-back cannot loop: that commit touches only `kubernetes/`, which is not in the workflow's paths filter.

## No OpenTofu changes

`opentofu/cloudflare` already gives `yak-shave.com` an apex and wildcard CNAME to the tunnel and routes both to Traefik; Cloudflare Universal SSL covers the certificate. The `www` route exists in `values.yaml` only because the wildcard CNAME answers for it — without a route of its own Traefik would 404 rather than redirect.

## Why the image strips a capability

The upstream Caddy binary ships `cap_net_bind_service` as a *file* capability so it can bind `:80`. This pod serves `:8080` behind Traefik and runs with `capabilities.drop: [ALL]`, under which `execve` refuses a binary whose permitted file capabilities are outside the bounding set:

```
exec /usr/bin/caddy: operation not permitted
```

The Dockerfile strips it with `setcap -r` rather than loosening the pod. Docker's default bounding set includes `NET_BIND_SERVICE`, so this only reproduces locally with:

```sh
docker run --rm --cap-drop ALL --read-only --user 1000:1000 \
  --tmpfs /config --tmpfs /data -p 8099:8080 yak-shave
```

## Read-only root

The container runs read-only and non-root, so the two paths Caddy writes to — `XDG_CONFIG_HOME=/config` for its autosaved config and `XDG_DATA_HOME=/data` for certificate storage it never uses — are `emptyDir`s. `fsGroup: 1000` is what makes them group-writable; without it they mount root-owned `0755` and Caddy cannot create its subdirectories.

## Caching

Set in `sites/yak-shave/Caddyfile`, and worth understanding before changing:

| Path | `Cache-Control` |
|------|-----------------|
| `/assets/*` (content-hashed) | `public, max-age=31536000, immutable` |
| Everything else | `public, max-age=300` |
| `/` | `no-store` (it is a redirect that moves) |
| **Any error** | **`no-store`** |

That last row is load-bearing. The header is chosen by request *path*, so without it a 404 under the asset prefix carries a one-year immutable header. During a rolling update Cloudflare can fetch new HTML, request its new CSS from a pod still running the old image, get a 404 — and cache that 404 for a year, pinning the site unstyled for everyone. That outage happened once; `handle_errors` now forces `no-store`, and the asset prefix moved from `_astro` to `assets` to escape the poisoned cache key.

Transient 404s during the mixed-version window of a rollout are still possible; they are simply no longer cacheable.

Note that Cloudflare does not edge-cache HTML by default (`cf-cache-status: DYNAMIC`), so `max-age=300` on pages is honoured by browsers, not the edge. Assets are edge-cached on extension.

## Availability

Two replicas, one per node, enforced by a `topologySpreadConstraint` with
`whenUnsatisfiable: DoNotSchedule`. A soft `podAntiAffinity` was not enough:
beelink carries a `PreferNoSchedule` taint for the descheduler rebalance, and
the scheduler weights that preference above either soft-spreading plugin, so
both replicas sat on rpi5 and a single node reboot would have taken the site
down.

The trade is that while a node is down or cordoned the second replica stays
`Pending` rather than doubling up on the surviving node. That is deliberate —
one replica serving beats two replicas sharing a failure domain — and the
`Yak Shave Running Degraded` alert is what stops that state going unnoticed.

A `PodDisruptionBudget` of `minAvailable: 1` keeps a drain from taking both.

| Alert | Fires when |
|-------|-----------|
| `Yak Shave Down` (critical) | No replica available for 5 minutes |
| `Yak Shave Running Degraded` (warning) | Only one replica available for a full hour |

Both put their hold-down inside the PromQL (`max_over_time` / `min_over_time`)
rather than in a `for:` field, which the `signoz-alerts` chart does not emit.

## Logs

Caddy writes a JSON access log to stdout, where the cluster's log pipeline
collects it. `/healthz` — the probe endpoint, polled by kubelet on every pod
every few seconds — is excluded with `log_skip`, so what lands in SigNoz is
real traffic. Probes deliberately do not hit `/`: that is a redirect whose
target changes with every post.

## Hardening

The pod meets PodSecurity `restricted`, not just `baseline`: non-root, no
privilege escalation, all capabilities dropped, read-only root, `seccompProfile:
RuntimeDefault`, and no service-account token mounted (Caddy never calls the
Kubernetes API). The namespace is not labelled to *enforce* `restricted` yet.

Security headers come from two places. Most of the Content-Security-Policy is a
per-page `<meta>` tag written by Astro, carrying a hash for every inline script
and style, so the policy needs no `'unsafe-inline'`. `frame-ancestors` is
ignored inside a meta tag, so the Caddyfile sends that one - plus
`X-Frame-Options` for older browsers - as real headers, on error responses too.

## Troubleshooting

**Site is up but unstyled.** Check whether an asset is 404ing and what `cf-cache-status` and `age` say:

```sh
curl -sI https://yak-shave.com/assets/<hash>.css | grep -i 'http/\|cache-control\|cf-cache-status\|age'
```

A cached 404 means something regressed the `handle_errors` block. Fix the Caddyfile, then purge the key at Cloudflare — the immutable header outlives a redeploy.

**Pods will not start, `operation not permitted`.** The `setcap -r` line was dropped from the Dockerfile. See above.

**`/` serves a post page instead of redirecting.** `caddy/latest.caddy` is generated by the `latestPostRedirect` integration in `astro.config.mjs` and copied into the image. An empty or comment-only snippet means the build found no published posts.

**A post does not appear.** It needs `public: true`. The build fails loudly on a filename/frontmatter date mismatch, a reserved slug, or a descent rung whose wording has drifted from the section it links to — check the workflow log rather than the pods.
