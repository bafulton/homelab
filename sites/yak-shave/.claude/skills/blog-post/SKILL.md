---
name: blog-post
description: Draft, structure, or publish a post for yak-shave.com. Use when writing a new post, converting a debugging session or an opinion into one, choosing between a yak shave and a rumination, or working out why a post fails the build.
---

# Writing for yak-shave.com

An Astro site in `sites/yak-shave`. Posts are markdown in `src/content/posts/`.

**`src/content.config.ts` is the source of truth for frontmatter.** It is
self-documenting and changes often — read it rather than trusting any field
list written down elsewhere, including here.

## Default mode: skeleton, not prose

**Ben writes the sentences. Unless he asks for a full draft, hand him a
skeleton.**

This is not modesty, it is editing economics. Replacing someone else's finished
paragraphs means line-editing prose you did not choose the shape of, which is
slower than writing your own and leaves a seam where the rewrite meets whatever
survived. A skeleton has nothing to replace.

The split that works: **the archaeology is yours, the voice is his.** Most of
the work in a shave post is reconstructing what actually happened — digging the
chain of causes out of git history, SigNoz, pod logs and PR threads, finding the
commit a line lived at, capturing the real output. Do that properly; it is the
part that makes the post true, and the part Ben would otherwise spend an evening
on. Then stop before the prose.

A skeleton is:

- frontmatter complete and valid, `public` left at its default
- `descent` drafted — rungs as realisations, in order
- one `##` per rung, worded **exactly** as the rung (the build checks this)
- under each heading, the **evidence**: the real command and its real output,
  a table of real numbers, a permalink pinned to the commit being discussed
- one `TK` line per section saying what that section has to establish

Nothing else. No connective paragraphs, no transitions, no opening line, and
above all no closing generalisation — the ending is the most voice-dependent
sentence in the post and the one most worth writing yourself.

`TK` is the newsroom convention for "to come" and is used here because it
appears in almost no English word, so `grep -n 'TK' <post>` finds every
placeholder and nothing else. A post with a `TK` in it is not ready to publish.

````markdown
## The disk was fine

TK — establish that every obvious check passed, so the reader stops
suspecting the disk and starts suspecting the name.

| check | result |
| --- | --- |
| SMB server pod | Running, 20d uptime, 0 restarts |
| `nc 192.168.1.201 445` | succeeded |

```console
$ tmutil destinationinfo
Name          : Family
Kind          : Network
URL           : smb://family@Time%20Machine._smb._tcp.local./Family
```
````

Write the prose out in full only when Ben asks for it in so many words — "write
it out", "full draft", "take a pass at the prose". Then the voice notes below
apply and they matter a great deal.

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

A draft renders under `npm run dev` and never in a build (`lib/posts.ts` gates
on `import.meta.env.DEV`), so the file in `src/content/posts/` is the draft as
well as the post: write it, preview it, rewrite it in place, with the schema and
the ladder/heading check running on every save instead of once at the end. The
rail tags an unpublished post `DRAFT`, which matters because the front page
renders the newest post — while you are drafting, that is your draft.

Both branches are `.strict()` — an unrecognised key fails the build. `date`
accepts quoted or unquoted; the schema normalises.

## Before flipping `public: true`

- [ ] `grep -n 'TK' <post>` returns nothing
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
live at `/<slug>/` — the whole site is the blog. `www` 301s to the apex and `/`
302s to the latest post. Tags are the commit SHA, so no `VERSION` file and no tag is
ever reused. See `sites/yak-shave/README.md` for the serving details.

## Housekeeping

Three posts carry `# STAND-IN DRAFTED BY CLAUDE` headers in their frontmatter:
`2026-09-02-committed-*`, `2026-09-18-signoz-*` and
`2026-10-15-sign-your-own-pull-requests`. They were drafted by Claude from
incident notes and are **live** under Ben's byline — he published them
deliberately, intending to rewrite them. Rewrite or delete; don't treat their
prose as a model for the house voice.

Which also means the ~520–580 word house length above is measured partly
against Claude-drafted text. Treat it as provisional; the one post that is
wholly Ben's is the Time Machine one.
