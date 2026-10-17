import rss from "@astrojs/rss";
import type { APIContext } from "astro";
import { getPosts } from "../lib/posts";

export async function GET(context: APIContext) {
  const posts = await getPosts();

  return rss({
    title: "Yak Shave",
    description:
      "Depth-first notes from a homelab: every fix, traced down to the thing that actually caused it.",
    site: context.site!,
    items: posts.map((post) => ({
      title: post.entry.data.title,
      pubDate: new Date(`${post.entry.data.date}T12:00:00Z`),
      link: `/${post.slug}/`,
      // Each kind's headline furniture is the most useful thing a reader can
      // see in a feed preview, so it travels with the summary rather than
      // being page-only.
      description: (post.entry.data.kind === "shave"
        ? [
            post.entry.data.summary,
            ...post.entry.data.descent.map((rung, i) => `${i + 1}. ${rung}`),
          ]
        : [post.entry.data.thesis, post.entry.data.summary]
      ).join("\n"),
      categories: post.entry.data.tags,
    })),
  });
}
