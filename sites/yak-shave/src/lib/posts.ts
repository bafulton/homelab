import { getCollection, type CollectionEntry } from "astro:content";

export type Kind = "shave" | "rumination";

export type Post = {
  entry: CollectionEntry<"posts">;
  slug: string;
};

const FILENAME_DATE = /^(\d{4}-\d{2}-\d{2})-(.+)$/;

// Posts live at the site root, so a slug that collides with a generated file
// would shadow it. Astro's duplicate-route error for this is opaque; this one
// names the post.
const RESERVED = new Set([
  "404",
  "rss.xml",
  "robots.txt",
  "sitemap-index.xml",
  "sitemap-0.xml",
  "favicon.svg",
  "assets",
  "_astro",
]);

// Noon UTC, so the calendar date is the same on both sides of the date line.
const at = (date: string) => new Date(`${date}T12:00:00Z`);

const DAY = new Intl.DateTimeFormat("en-GB", {
  day: "2-digit",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});
export const formatDay = (date: string) => DAY.format(at(date)).toUpperCase();

/**
 * Published posts, newest first.
 *
 * Everything here throws at build time rather than rendering something wrong:
 * a filename whose date disagrees with its frontmatter is a mistake you want
 * to find in CI, not six months later when the archive sorts oddly.
 */
export async function getPosts(kind?: Kind): Promise<Post[]> {
  const entries = await getCollection("posts", (p) => p.data.public);

  const withSlugs = entries.map((entry) => {
    const match = FILENAME_DATE.exec(entry.id);
    if (!match) {
      throw new Error(`Post "${entry.id}" must be named YYYY-MM-DD-<slug>.md`);
    }
    const [, filenameDate, slug] = match;
    if (filenameDate !== entry.data.date) {
      throw new Error(
        `Post "${entry.id}" is dated ${entry.data.date} in frontmatter but ` +
          `${filenameDate} in its filename.`,
      );
    }
    if (RESERVED.has(slug!)) {
      throw new Error(
        `Post "${entry.id}" has the slug "${slug}", which collides with a ` +
          `file the site generates. Rename it.`,
      );
    }
    return { entry, slug: slug!, date: entry.data.date };
  });

  return withSlugs
    .sort((a, b) => b.date.localeCompare(a.date))
    .filter(({ entry }) => !kind || entry.data.kind === kind)
    .map(({ entry, slug }) => ({ entry, slug }));
}

export type KindGroup = { kind: Kind; label: string; posts: Post[] };

/** The rail's two sections, newest first within each, empty ones dropped. */
export function groupByKind(posts: Post[]): KindGroup[] {
  return (["shave", "rumination"] as const)
    .map((kind) => ({
      kind,
      label: kind === "shave" ? "Yak Shaves" : "Ruminations",
      posts: posts.filter((p) => p.entry.data.kind === kind),
    }))
    .filter((group) => group.posts.length > 0);
}
