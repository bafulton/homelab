---
name: blog-post
description: Draft, structure, or publish a post for yak-shave.com. Use when writing a new post, converting a debugging session or an opinion into one, choosing between a yak shave and a rumination, or working out why a post fails the build.
---

# Writing for yak-shave.com

An Astro site in `sites/yak-shave`. Posts are markdown in `src/content/posts/`.

**`src/content.config.ts` is the source of truth for frontmatter.** It is
self-documenting and changes often — read it rather than trusting any field
list written down elsewhere, including here.

## Pick the kind first

The schema is a discriminated union on `kind`; each branch requires a different
spine field, and that field is the post's actual argument.

| | `shave` | `rumination` |
| --- | --- | --- |
| it is | reporting | the editorial page |
| spine field | `descent` (2–8 rungs) | `thesis` (one sentence) |
| the question | how far down did it go? | what do I think, and why? |
| starts from | something broke | something is worth arguing |

If you can't write the `thesis` in one line, it isn't finished being thought
about. If the `descent` has fewer than two rungs, it's a note, not a post.

## The descent is the structure

For a shave, `descent` is frontmatter and the `Deck` component renders it as a
Victorian multi-deck headline. **Don't repeat it as a list in the body** — the
reader has already seen it. Each rung gets a `##` section, in order, and the
body is the evidence for that rung.

Rungs are realisations, not steps. "Nothing was advertising" is a rung;
"Checked the pod logs" is not.

**A rung and its section carry the same words.** The ladder links each rung to
its section, so rung *n* must read exactly as the *n*-th `##` heading. This is
checked at build time: drift fails the build naming both strings. Sections past
the last rung are free — that's where "The fix" and whatever you close with
live. A post with fewer sections than rungs keeps a plain, unlinked ladder
rather than a half-live one.

## Shape: show, don't narrate

Prefer a table or a block of real terminal output over a paragraph describing
one. Verified against `src/styles/global.css`:

| element | renders | notes |
| --- | --- | --- |
| tables | **yes, elaborately** | newspaper rules, tabular numerals, uppercase heads — first-class, use them |
| fenced code | yes | Shiki, `github-light`, deliberately monochrome |
| `console` fences | yes | use for real captured output; keep the `$` prompt |
| blockquote | yes | good for a one-paragraph aside |
| inline `<svg>` | yes | `max-width:100%`, no wrapper component yet |
| `<img>` | yes | styled, but nothing in `public/` yet and no `astro:assets` pipeline |
| **mermaid** | **no** | not installed; a ` ```mermaid ` fence renders as a code block |

Diagrams mean hand-written inline SVG for now. Honour the monochrome palette
(`--ink`, `--hairline`) rather than introducing colour.

## Voice and length

Existing posts run **~520–580 words**. Short, declarative, past tense for the
narrative and present tense for the conclusion. No throat-clearing intro and no
"in this post I will."

Earn the ending: the last section generalises past the specific tool. "The real
conclusion is not about Talos either" — the post is about the class of mistake,
not the command that fixed it.

> `2026-10-16-seven-layers-under-a-time-machine-backup.md` runs ~1,200 words,
> roughly double the house length. It's the table-heavy end of the range. Treat
> it as the ceiling, not the target.

## Linking to the homelab repo

The repo is public: `https://github.com/bafulton/homelab`. Link generously.

**Pin links to the commit being discussed, not `main`.** Most code a shave
quotes has since been rewritten — a `main` link either 404s or shows the fixed
version, which quietly undercuts the story.

| linking to | ref |
| --- | --- |
| the broken thing | the commit where it was still broken |
| the fix | `main` |

Say so once, near the top, so readers know a link means "as it was then". Verify
line ranges before committing to them; they drift.

## The build enforces two things

1. **Filename is `YYYY-MM-DD-<slug>.md`**, and that date must equal the `date`
   in frontmatter. `lib/posts.ts` throws at build time if they disagree.
2. **`public: false` by default.** Drafts live in the repo and simply don't
   publish. Flipping to `true` is the editorial act.

Both branches are `.strict()` — an unrecognised key fails the build. `date`
accepts quoted or unquoted; the schema normalises.

## Before flipping `public: true`

- [ ] Filename date matches frontmatter date
- [ ] `descent` rungs are realisations, and the body doesn't repeat them
- [ ] Every claim has its evidence — output, table, or a pinned link
- [ ] No secrets, tokens, UUIDs, or other people's names (check sparsebundle and
      hostname output especially)
- [ ] Private IPs are fine; the repo is public anyway
- [ ] Links resolve, and line ranges bracket what you claim
- [ ] `npx astro build` passes

## Publishing

Wired up. Publishing a post is one push to main; nothing in `kubernetes/` is
edited by hand.

```
push to main (sites/yak-shave/**)
  -> .github/workflows/build-site.yaml
       npm ci && npm run build
       build ghcr.io/bafulton/yak-shave:sha-<commit>  (amd64 + arm64)
       commit that tag into kubernetes/apps/yak-shave/values.yaml
  -> ArgoCD syncs; Caddy serves the static files
```

Served at `https://yak-shave.com` through the existing Cloudflare Tunnel. Posts
live at `/<slug>/` — the whole site is the blog. `www` 301s to the apex, `/`
302s to the latest post, and the old `/blog/*` paths 301 to the root. Tags are the commit SHA, so no `VERSION` file and no tag is
ever reused. See `sites/yak-shave/README.md` for the serving details.

## Housekeeping

Three posts carry `# STAND-IN DRAFTED BY CLAUDE` headers and are set
`public: false`, so they sit in the repo without going out under Ben's byline.
Rewrite or delete them, then flip the flag.

Because those three are unpublished, the ~520–580 word house length above is
measured against drafts rather than shipped posts. Treat it as provisional.
