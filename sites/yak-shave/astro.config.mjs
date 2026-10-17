// @ts-check
import { defineConfig, fontProviders } from "astro/config";
import sitemap from "@astrojs/sitemap";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
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
                // /index.html as well as /: the file is reachable under its
                // own name, and it is precisely the URL whose fragment links
                // rot when a newer post takes the front page.
                "@root path / /index.html",
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

/**
 * Fail the build if any inline script or style is missing from its page's CSP.
 *
 * Astro hashes what it manages, but anything it deliberately does not touch -
 * an `is:inline` script above all - is invisible to it. A missing hash does
 * not announce itself: the browser blocks the tag and the page merely behaves
 * slightly wrong, which is the sort of thing that is noticed months later.
 */
function assertInlineHashesCovered() {
  const INLINE = /<(script|style)(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/\1>/g;
  const META = /<meta http-equiv="content-security-policy" content="([^"]*)"/i;

  return {
    name: "assert-inline-hashes-covered",
    hooks: {
      "astro:build:done": async ({ dir, logger }) => {
        const pages = (await readdir(fileURLToPath(dir), { recursive: true }))
          .filter((f) => f.endsWith(".html"));

        let checked = 0;
        for (const page of pages) {
          const html = await readFile(new URL(page, dir), "utf8");
          const csp = html.match(META)?.[1];
          if (!csp) throw new Error(`${page} has no CSP meta tag.`);

          for (const [, tag, body] of html.matchAll(INLINE)) {
            const digest =
              "sha256-" + createHash("sha256").update(body).digest("base64");
            if (!csp.includes(digest)) {
              throw new Error(
                `${page}: an inline <${tag}> is not covered by the page's CSP ` +
                  `(${digest}). If this is the is:inline theme script, update ` +
                  `scriptDirective.hashes in this file to match it.`,
              );
            }
            checked++;
          }
        }
        logger.info(`${checked} inline scripts/styles covered by CSP`);
      },
    },
  };
}

export default defineConfig({
  site: "https://yak-shave.com",
  fonts,

  /*
   * Content Security Policy.
   *
   * Astro hashes every inline <script> and <style> it emits and writes them
   * into script-src/style-src, so the policy does not need 'unsafe-inline' -
   * which is the only version of a CSP worth having on a page that carries an
   * inline theme script and inlined critical CSS.
   *
   * default-src 'self' is only possible because the fonts are self-hosted;
   * it would otherwise have to allowlist fonts.googleapis.com and
   * fonts.gstatic.com. Links out to GitHub are navigations, which CSP does
   * not restrict, so nothing on the site needs an exception.
   *
   * frame-ancestors is deliberately not here: it is ignored in a meta tag,
   * which is how a static build delivers CSP. The Caddyfile sends that one as
   * a header.
   */
  security: {
    csp: {
      /*
       * The theme script in Base.astro is `is:inline` - it has to run before
       * first paint or a night reader gets a white flash - and `is:inline`
       * is precisely the directive that tells Astro not to process a script,
       * so Astro does not hash it. It currently executes only because a
       * meta-delivered policy does not cover the markup above it, which is an
       * accident of ordering rather than a permission.
       *
       * Hashing it explicitly makes it allowed rather than merely unreached.
       * `assertInlineHashesCovered` below fails the build if this value stops
       * matching the script, so editing one without the other cannot ship.
       */
      scriptDirective: {
        hashes: ["sha256-Qh3B7/ms8U4ygcRlkxd9Sem9GAHbAN3PTlPY3n5hD+0="],
      },
      directives: [
        "default-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'none'",
      ],
    },
  },
  build: {
    // Was "_astro". A 404 under that prefix got cached by Cloudflare with a
    // one-year immutable header (see the Caddyfile's handle_errors), so every
    // asset URL moves to a prefix with nothing poisoned in it.
    assets: "assets",
  },
  integrations: [
    // / 302s to the newest post, so listing it would put a redirect in the
    // sitemap; the post it points at is listed on its own.
    sitemap({ filter: (page) => new URL(page).pathname !== "/" }),
    latestPostRedirect(),
    assertInlineHashesCovered(),
  ],
  markdown: {
    shikiConfig: {
      // Monochrome page, monochrome code. `github-light` is the least
      // saturated of the bundled themes; the CSS below desaturates the rest.
      theme: "github-light",
      wrap: true,
    },
  },
});
