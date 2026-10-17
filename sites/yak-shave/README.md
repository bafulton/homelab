# yak-shave.com

The blog. An Astro static site: markdown in, plain HTML out, zero client
JavaScript beyond a theme toggle.

## Writing a post

Create `src/content/posts/YYYY-MM-DD-<slug>.md`. The URL is the slug with the
date stripped, so the file above publishes at `/<slug>/` — the permanent,
shareable link for that post. The whole site is the blog, so posts sit at the
root rather than under a section.

Every post declares a `kind`, and the two kinds take different frontmatter.
The rail groups by kind, so adding a post files it automatically.

### `kind: shave`

Something broke; here is how far down it went.

```yaml
---
kind: shave
title: Seven layers under a failed Time Machine backup
date: "2026-10-16"          # matches the filename prefix
summary: One sentence. Shown on the index and in the feed.
descent:                     # 2-8 rungs, symptom first, cause last
  - Time Machine says the backup disk is unavailable
  - The disk is fine - nothing is advertising it over mDNS
  - The mDNS advertiser has been OOMKilled 296 times
resolution: One line, what actually ended the descent.
tags: [kubernetes, homelab, mdns]   # up to 6, lowercase, hyphens allowed
public: true                 # drafts stay in the repo until this is true
---
```

`descent` is the format, not decoration. The renderer draws it as a Victorian
multi-deck headline: each rung steps further right than the one above, so the
shape of the investigation is visible before any prose, and the last rung —
the actual cause — is set in ink rather than grey. The descent also travels
with the RSS entry, where it is the most useful thing a reader can see.

Two to eight rungs. One makes it a note rather than a descent; nine is
probably two posts.

**Write the prose as one `##` section per rung and the ladder becomes
navigation.** Each rung links to the section that covers it, matched in order:
rung one to the first section, rung two to the second, and so on. Sections
past the last rung are free — "The fix", "What I'd keep" and anything else you
want to close with.

The linking is all-or-nothing per post: if a shave has fewer sections than
rungs, the whole ladder stays plain text rather than leaving some rungs
jumping and others dead, which is more confusing than a ladder that never
moves.

### `kind: rumination`

A position on building software, and why you hold it. Yaks are ruminants, so
the section name is the same joke as the domain.

```yaml
---
kind: rumination
title: Sign your own pull requests
date: "2026-10-15"
summary: One sentence. Shown on the index and in the feed.
thesis: A "written by Claude" footer is a way of not signing your own work.
tags: [ai, pull-requests, code-review]
public: true
---
```

A shave descends, so it gets a ladder. A rumination takes a position, so it
gets what an editorial page gives a position: `thesis`, one sentence, set
large under a rule and labelled **The claim**. There is no depth meter,
because there is no depth to report.

Keep the claim to a line. One that cannot be stated in a sentence is not
finished being thought about, which is why the schema caps it at 200
characters.

### Tags are stored but not shown

`tags` is still validated and still rides along as RSS `categories`, but
nothing renders it on the page — a tag list under four posts is a word cloud,
not navigation. Keep tagging posts if you like; when there are enough for the
tags to mean something, surfacing them is a rendering change, not a migration.

### Publishing

Set `public: true` when it is ready. Until then the post lives in the repo,
renders in `npm run dev`, and stays off the built site — drafts need no
separate directory and no branch.

Quote the date or leave it bare; both work. The schema normalises it.

### Everything is checked at build time

`npm run build` fails, rather than publishing something wrong, when:

- a filename date disagrees with its frontmatter `date`
- a shave's `descent` has fewer than two rungs or more than eight
- a rumination carries `descent`, or a shave carries `thesis` (the schema is a
  discriminated union of two `.strict()` shapes, so the furniture of one kind
  cannot leak into the other)
- a tag is not lowercase-and-hyphens, or there are more than six
- any unknown key appears in the frontmatter

Same doctrine as `images/README.md`: a bad post is a red CI check, not a
surprise on the live site.

## Running it

```sh
npm install
npm run dev      # http://localhost:4321
npm run build    # -> dist/
```

## Design

Newsprint brutalism, one ink. There is no accent colour: emphasis is carried
by inverting ink and paper, by rule weight, and by type size, the way a
one-colour press had to do it. Everything derives from two values in
`src/styles/tokens.css`, which is also what makes the dark theme a two-line
swap.

- **One typeface: Newsreader**, a news text face that holds up at headline
  sizes. An earlier draft set headlines in Bodoni Moda, a Didone whose
  hairline serifs and extreme stroke contrast made them hard to read, with
  Spectral underneath — two serifs plus a mono reading as three competing
  voices.
- **JetBrains Mono appears only where monospacing does real work**: code
  blocks, console output, YAML. Never as a second voice for UI text. Tables
  are set in the text face, with mono only on the `code` spans inside them.
- The yak is a solid woodcut silhouette in `src/components/Yak.astro`, filled
  with `currentColor` so it inverts with the theme. Edit the path data
  directly; it is hand-drawn, not traced.
- The post page's descent deck borrows its logic from Victorian multi-deck
  headlines, where stacked subheads summarised a story before the first
  paragraph.

The yak is the whole nameplate. There is no wordmark, no standing line and no
colophon: the mark carries the identity, the site name is in the `<title>` and
an `sr-only` span, and the address bar says the rest. The scheme toggle is a
sun/moon glyph in the top right, where readers already look for it, positioned
absolutely so it scrolls away rather than sitting on the text.

Each post carries its byline and dateline **below** the headline and summary,
the way a paper sets them. There are no issue numbers and no depth meter —
both were counting things nobody needed counted.

Layout is a two-column journal. The front page is the latest post in full,
with every other post in a sticky left rail grouped into **Yak Shaves** and
**Ruminations**, newest first. There is no month grouping — at a few posts a
year it invents structure rather than revealing it — and no section pages,
because the rail already is the section list. A post does not restate its own
kind either: the rail has already said which it is. No search, no pagination,
no reading time, no previous-post link, no tag list. The restraint is the
design.

The one place ink and paper swap is the **The fix** label on a shave. Keeping
it to a single element is what makes it read as emphasis rather than
decoration.

**`/` redirects to the latest post** (302), so a post has one address. Without
that, the front page renders the latest post inline and every fragment link on
it — the descent ladder most of all — reads as `yak-shave.com/#some-section`
and breaks the moment a newer post takes over the front page.

The redirect target is generated at build time by the `latest-post-redirect`
integration in `astro.config.mjs`, which reads it back out of the built
`index.html`'s canonical link rather than recomputing it, so the redirect
cannot disagree with the page's own idea of where it lives. It lands in
`caddy/latest.caddy` (gitignored, built artefact) and the Dockerfile copies it
to `/etc/caddy/`.

It is a **302, never a 301**: the latest post changes, and browsers and CDNs
cache permanent redirects — a 301 would pin a returning visitor to whichever
post happened to be newest the first time they visited.

`dist/index.html` is still built, and still carries the post's canonical URL,
so the site keeps working as plain static files anywhere the redirect is not
applied.

## How it ships

Publishing is one push to main. Nothing in `kubernetes/` is edited by hand.

```
push to main (sites/yak-shave/**)
  -> .github/workflows/build-site.yaml
       npm ci && npm run build          # schema + ladder checks run here
       build ghcr.io/bafulton/yak-shave:sha-<commit>   (amd64 + arm64)
       commit that tag into kubernetes/apps/yak-shave/values.yaml
  -> ArgoCD syncs the new tag
```

The static output is built on the runner, not inside the image: Astro emits
plain HTML, so it is identical on every architecture, and building it once
natively keeps `npm ci` off an emulated arm64 build. The image is then just
Caddy plus `dist/`.

Tags are the commit SHA, so every deploy is immutable. That is why there is no
`VERSION` file here and why Renovate does not track `image.tag` — the stale
cached-layer failure the `images/` guard exists for cannot happen when no tag
is ever reused.

The write-back commit only touches `kubernetes/`, which is not in the
workflow's path filter, so it cannot retrigger the workflow.

The GHCR package published public on its own, unlike the ones in `images/`
which needed flipping by hand. If a future replica ever sits in
`ImagePullBackOff`, check that first.

### Serving

The image strips `cap_net_bind_service` from the Caddy binary. Upstream sets
it as a file capability so Caddy can bind :80; the pod runs with
`capabilities.drop: [ALL]`, and execve refuses a file whose permitted
capabilities are not in the bounding set — the container dies with
`exec /usr/bin/caddy: operation not permitted` before writing a log line.
Serving :8080 means the capability is unnecessary anyway.

Reproduce that locally with `docker run --cap-drop ALL`. Without the flag,
Docker's default bounding set includes `NET_BIND_SERVICE` and the container
starts fine, which hides the failure until it reaches the cluster.

Caddy serves `/srv` on :8080, read-only and non-root, with `/config` and
`/data` as emptyDirs. Two replicas with soft anti-affinity, unpinned so they
can land on any node (`ocifree` included, once it joins) — a stateless site
should not go dark because one node is draining.

Astro writes directory-style URLs, so `try_files` resolves `/<slug>` as well
as `/<slug>/`. Posts briefly lived under `/blog/`, and the feed went out with
those links, so `/blog/*` 301s to the root equivalent — permanent is right
there, since those paths will never mean anything else.
`/_astro/*` is content-hashed and cached for a year;
everything else gets five minutes. A miss serves `404.html` with a real 404.

To run the image locally exactly as the cluster does:

```sh
npm ci && npm run build
docker build -t yak-shave .
docker run --rm --read-only --user 1000:1000 \
  --tmpfs /config --tmpfs /data -p 8099:8080 yak-shave
```

### Still to do

1. **Three posts are unpublished stand-ins** — `2026-09-02-committed-*`,
   `2026-09-18-signoz-*` and `2026-10-15-sign-your-own-pull-requests`. They
   were drafted by Claude and are set `public: false` so they stay in the repo
   without going out under your byline. Rewrite or delete them, then flip the
   flag.
2. **Self-host the fonts.** They load from Google. Moving them to `@fontsource`
   removes a third-party request from a page served out of the cluster.
3. **Decide where RSS is advertised.** The feed builds and is declared in
   `<link rel="alternate">`, so feed readers find it, but no visible link
   points at it.

## Decisions

**Astro, not SvelteKit or Hugo.** Typed frontmatter catches a malformed post in
CI. Zero JS ships by default. The reference site (jomcgi.dev) uses SvelteKit,
but only because its blog is one route inside a larger app that already runs a
server; a standalone content site gains nothing from that runtime.

**Markdown in git, not a CMS.** Posts are immutable once published, so there is
nothing for a database to do that git does not do better — and a CMS would mean
a stateful app with a volume to back up. If browser or phone authoring ever
matters, a git-based CMS (Sveltia) adds an `/admin` route that commits markdown
through the GitHub API, with no backend and no database.

**In the homelab monorepo.** One commit can carry a post and a design change
together, and ArgoCD already watches this repo.
