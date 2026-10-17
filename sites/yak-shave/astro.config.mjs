// @ts-check
import { defineConfig, fontProviders } from "astro/config";
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

/*
 * Self-hosted type.
 *
 * The woff2 files come from the Fontsource npm packages, so Renovate keeps
 * them current and the build never reaches out to fonts.googleapis.com - which
 * used to cost a blocking cross-origin stylesheet before any text could paint.
 *
 * Both families are variable, and only the `latin` subset ships: a glyph
 * outside it (a Polish or Vietnamese name, say) falls through to the next
 * family in the stack per-character, which is what the fallbacks are for.
 *
 * The `opsz` cut of Newsreader carries two axes - wght 200..800 and opsz 6..72.
 * Browsers set `font-optical-sizing: auto` by default, so a 2.6rem headline
 * gets the fine-serifed optical size and body copy gets the sturdy one, with
 * no CSS asking for it. The old Google request served discrete 400/500/600
 * instances, so the 700s in the stylesheet were being faux-bolded; against a
 * real axis they are now drawn.
 */
const SERIF = "@fontsource-variable/newsreader/files/newsreader-latin-opsz";
const MONO = "@fontsource-variable/jetbrains-mono/files/jetbrains-mono-latin-wght";

const fonts = [
  {
    name: "Newsreader",
    cssVariable: "--font-serif",
    provider: fontProviders.local(),
    display: "swap",
    // Ends in a generic family, which is what lets Astro generate the
    // metric-adjusted fallback face that keeps the swap from shifting text.
    fallbacks: ["Georgia", "Times New Roman", "Times", "serif"],
    options: {
      variants: [
        { src: [`${SERIF}-normal.woff2`], weight: "200 800", style: "normal" },
        { src: [`${SERIF}-italic.woff2`], weight: "200 800", style: "italic" },
      ],
    },
  },
  {
    name: "JetBrains Mono",
    cssVariable: "--font-mono",
    provider: fontProviders.local(),
    display: "swap",
    fallbacks: ["ui-monospace", "SFMono-Regular", "Menlo", "monospace"],
    // `monospace` resolves to Courier New, so the metric-adjusted face would
    // be a worse permanent fallback than Menlo for the console output and
    // YAML this family exists to set. Code is a small share of the page, and
    // mono metrics are close enough that the unoptimized swap barely moves.
    optimizedFallbacks: false,
    options: {
      variants: [
        // No italic cut: nothing on the site sets mono in italic.
        { src: [`${MONO}-normal.woff2`], weight: "100 800", style: "normal" },
      ],
    },
  },
];

export default defineConfig({
  site: "https://yak-shave.com",
  fonts,
  build: {
    // Was "_astro". A 404 under that prefix got cached by Cloudflare with a
    // one-year immutable header (see the Caddyfile's handle_errors), so every
    // asset URL moves to a prefix with nothing poisoned in it.
    assets: "assets",
  },
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
