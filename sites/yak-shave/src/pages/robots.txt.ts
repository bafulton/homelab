import type { APIContext } from "astro";

/**
 * Generated rather than dropped in public/, so the host comes from the `site`
 * config and cannot drift from the sitemap it advertises.
 */
export function GET(context: APIContext) {
  const body = [
    "User-agent: *",
    "Allow: /",
    "",
    `Sitemap: ${new URL("sitemap-index.xml", context.site!).href}`,
    "",
  ].join("\n");

  return new Response(body, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
