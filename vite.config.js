import { defineConfig } from "vite";
import { sveltekit } from "@sveltejs/kit/vite";

const tauriHost = process.env.TAURI_DEV_HOST;
const bindHost = process.env.VITE_DEV_BIND || tauriHost || false;
const hmrHost = process.env.VITE_HMR_HOST || process.env.VITE_DEV_HOST || tauriHost || "";

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [sveltekit()],

  // Keep diagnostics visible when running alongside the API server.
  clearScreen: false,
  // A fixed port keeps local clients and the retained Tauri shell in sync.
  server: {
    port: 1420,
    strictPort: true,
    host: bindHost,
    hmr: hmrHost
      ? {
          protocol: "ws",
          host: hmrHost,
          port: tauriHost ? 1421 : 1420,
        }
      : undefined,
    watch: {
      // Backend changes do not require a web reload.
      ignored: ["**/src-tauri/**"],
    },
  },
}));
