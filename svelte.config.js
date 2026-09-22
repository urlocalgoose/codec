// Tauri doesn't have a Node.js server to do proper SSR
// so we use adapter-static with a fallback to index.html to put the site in SPA mode
// See: https://svelte.dev/docs/kit/single-page-apps
// See: https://v2.tauri.app/start/frontend/sveltekit/ for more info
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
