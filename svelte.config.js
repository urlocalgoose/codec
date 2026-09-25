// The Go server serves this static web app; client routes fall back to index.html.
// See: https://svelte.dev/docs/kit/single-page-apps
import adapter from "@sveltejs/adapter-static";
import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    // Release builds provide a stable content-specific ID for app/SW caches.
    // Local development keeps SvelteKit's normal version behavior.
    ...(process.env.CODEC_BUILD_ID
      ? { version: { name: process.env.CODEC_BUILD_ID } }
      : {}),
    adapter: adapter({
      fallback: "index.html",
    }),
    serviceWorker: {
      // app.html registers it manually so Tauri (localhost streams) stays out.
      register: false,
    },
  },
};

export default config;
