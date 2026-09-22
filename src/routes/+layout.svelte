<script lang="ts">
  import { onMount } from "svelte";
  import { observeMobileViewport } from "$lib/mobile-viewport";
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
    const stopViewport = observeMobileViewport(window, document);
    document.addEventListener("pointerdown", pointer, true);
    document.addEventListener("keydown", keyboard, true);
    return () => {
      document.removeEventListener("pointerdown", pointer, true);
      document.removeEventListener("keydown", keyboard, true);
      stopViewport();
      delete root.dataset.inputModality;
    };
  });
</script>

{@render children()}
