// @ts-check
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

/**
 * Emit the Caddy snippet that redirects / to the latest post.
 *
 * The front page renders the latest post, so every fragment link on it - the
 * descent ladder above all - would read as yak-shave.com/#some-section and
 * break the moment a newer post takes over the front page. Redirecting / to
 * that post's own URL makes every link on the page durable, and gives the
 * post one address instead of two.
 *
 * The target is read back out of the built index.html's canonical link rather
 * than recomputed here, so the redirect cannot disagree with what the page
 * itself claims is canonical.
 */
function latestPostRedirect() {
  return {
    name: "latest-post-redirect",
    hooks: {
      "astro:build:done": async ({ dir, logger }) => {
        const html = await readFile(new URL("index.html", dir), "utf8");
        const canonical = html.match(/<link rel="canonical" href="([^"]+)"/)?.[1];
        const target = canonical ? new URL(canonical).pathname : undefined;

        // With no posts, / is its own canonical and redirecting it would loop.
        const snippet =
          !target || target === "/"
            ? "# No published posts, so / serves the front page directly.\n"
            : [
                "@root path /",
                "# 302, never 301: the latest post changes, and a permanent",
                "# redirect would be cached - pinning a returning visitor to",
                "# whichever post happened to be newest on their first visit.",
                'header @root Cache-Control "no-store"',
                `redir @root ${target} 302`,
                "",
              ].join("\n");

        const out = path.join(process.cwd(), "caddy");
        await mkdir(out, { recursive: true });
        await writeFile(path.join(out, "latest.caddy"), snippet);
        logger.info(`/ redirects to ${target ?? "(no posts)"}`);
      },
    },
  };
}

export default defineConfig({
  site: "https://yak-shave.com",
  integrations: [sitemap(), latestPostRedirect()],
  markdown: {
    shikiConfig: {
      // Monochrome page, monochrome code. `github-light` is the least
      // saturated of the bundled themes; the CSS below desaturates the rest.
      theme: "github-light",
      wrap: true,
    },
  },
});
