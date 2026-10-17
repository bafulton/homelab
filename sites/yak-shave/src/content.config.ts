import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TAG = /^[a-z0-9][a-z0-9-]{0,23}$/;

/**
 * Two kinds of post, and the paper has a section for each.
 *
 * A yak shave is reporting: something broke, here is how far down it went.
 * A rumination is the editorial page: here is a position and why I hold it.
 * They want different furniture, so the schema branches rather than making
 * every field optional and hoping the renderer guesses right.
 */
const base = z.object({
  title: z.string().min(1).max(120),

  // Normalised to a YYYY-MM-DD string, never carried around as a Date: a bare
  // date parses as UTC midnight and renders as the previous day for anyone
  // west of Greenwich. YAML turns an unquoted 2026-10-16 into a Date and a
  // quoted one into a string, so both are accepted rather than making every
  // post remember the quotes.
  date: z
    .union([z.string().regex(DATE, "date must be YYYY-MM-DD"), z.date()])
    .transform((v) => (typeof v === "string" ? v : v.toISOString().slice(0, 10))),

  summary: z.string().min(1).max(240),
  tags: z.array(z.string().regex(TAG)).max(6).default([]),

  // Explicit opt-in. Drafts live in the repo and simply do not publish.
  public: z.boolean().default(false),
});

const shave = base
  .extend({
    kind: z.literal("shave"),

    // The descent is the format, not decoration: a chain of realisations from
    // the visible symptom down to the actual cause. At least two so a post
    // cannot quietly become a listicle; the renderer draws it as the deck.
    descent: z
      .array(z.string().min(1).max(120))
      .min(2, "a shave needs at least two layers of descent")
      .max(8, "more than eight layers is probably two posts"),
  })
  .strict();

const rumination = base
  .extend({
    kind: z.literal("rumination"),

    // The position being argued, in one sentence. A rumination that cannot
    // state its claim in a line is not finished being thought about.
    thesis: z.string().min(1).max(200),
  })
  .strict();

const posts = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/posts" }),
  schema: z.discriminatedUnion("kind", [shave, rumination]),
});

export const collections = { posts };
