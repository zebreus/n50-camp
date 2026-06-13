import { defineConfig } from "astro/config";
import preact from "@astrojs/preact";

// Preact integration so <Tents> can be authored in real JSX and rendered to
// static HTML at build time. No `client:*` directive is used, so the site ships
// zero JavaScript — the camera fly-in and reveals are pure CSS.
export default defineConfig({
  integrations: [preact()],
});
