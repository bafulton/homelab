// @ts-check
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://yak-shave.com",
  integrations: [sitemap()],
  markdown: {
    shikiConfig: {
      // Monochrome page, monochrome code. `github-light` is the least
      // saturated of the bundled themes; the CSS below desaturates the rest.
      theme: "github-light",
      wrap: true,
    },
  },
});
