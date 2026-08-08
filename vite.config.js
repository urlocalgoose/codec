import { defineConfig } from "vite";
import { sveltekit } from "@sveltejs/kit/vite";

const tauriHost = process.env.TAURI_DEV_HOST;
const bindHost = process.env.VITE_DEV_BIND || tauriHost || false;
const hmrHost = process.env.VITE_HMR_HOST || process.env.VITE_DEV_HOST || tauriHost || "";

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [sveltekit()],

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
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
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },
}));
