<script lang="ts">
  import { onMount } from "svelte";
  import "../app.css";
  import "../mobile.css";
  import "../mobile-library-parity.css";
  import "../mobile-player-parity.css";
  import "../mobile-shell-parity.css";

  let { children } = $props();

  onMount(() => {
    const root = document.documentElement;
    const pointer = () => { root.dataset.inputModality = "pointer"; };
    const keyboard = (event: KeyboardEvent) => {
      if (event.key === "Tab" || event.key.startsWith("Arrow") || event.key === "Enter" || event.key === " ") {
        root.dataset.inputModality = "keyboard";
      }
    };
    // Dialog autofocus and restored focus should not paint a keyboard ring
    // after a tap. Keep focus itself intact for assistive technology.
    pointer();
    const standalone = matchMedia("(display-mode: standalone)");
    let viewportFrame = 0;
    const updateViewport = () => {
      cancelAnimationFrame(viewportFrame);
      viewportFrame = requestAnimationFrame(() => {
        const installed = standalone.matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;
        if (installed) {
          // Some iOS Home Screen releases resolve dvh inside the safe area.
          // Use the actual layout viewport; safe-area padding belongs only to
          // controls inside it, never to the height of the screen itself.
          root.dataset.standalone = "true";
          root.style.setProperty("--app-viewport-height", `${window.innerHeight}px`);
        } else {
          delete root.dataset.standalone;
          root.style.removeProperty("--app-viewport-height");
        }
      });
    };
    updateViewport();
    window.addEventListener("resize", updateViewport);
    window.addEventListener("pageshow", updateViewport);
    window.addEventListener("orientationchange", updateViewport);
    document.addEventListener("visibilitychange", updateViewport);
    standalone.addEventListener("change", updateViewport);
    document.addEventListener("pointerdown", pointer, true);
    document.addEventListener("keydown", keyboard, true);
    return () => {
      document.removeEventListener("pointerdown", pointer, true);
      document.removeEventListener("keydown", keyboard, true);
      cancelAnimationFrame(viewportFrame);
      window.removeEventListener("resize", updateViewport);
      window.removeEventListener("pageshow", updateViewport);
      window.removeEventListener("orientationchange", updateViewport);
      document.removeEventListener("visibilitychange", updateViewport);
      standalone.removeEventListener("change", updateViewport);
      root.style.removeProperty("--app-viewport-height");
      delete root.dataset.standalone;
      delete root.dataset.inputModality;
    };
  });
</script>

{@render children()}
