<script lang="ts">
  import { onMount } from "svelte";
  import { Maximize2, Minimize2 } from "lucide-svelte";
  import { SPECTRO_BANDS, type SpectroSampler } from "$lib/visualizer";
  import type { Track } from "$lib/types";

  let {
    sampler,
    currentTrack,
    theme
  }: {
    sampler: SpectroSampler | null;
    currentTrack: Track | null;
    theme: string;
  } = $props();

  let wrapEl: HTMLDivElement | undefined = $state();
  let canvasEl: HTMLCanvasElement | undefined = $state();
  let isFullscreen = $state(false);

  function toggleFullscreen() {
    if (document.fullscreenElement) {
      void document.exitFullscreen();
    } else if (wrapEl) {
      void wrapEl.requestFullscreen().catch(() => {
        // Fullscreen can be denied (iframe policy, etc.) — nothing to do.
      });
    }
  }

  let colors = { bg: "#000", accent: "#f47b3f", hot: "#fff" };

  function readColors() {
    if (!wrapEl) {
      return;
    }
    const style = getComputedStyle(wrapEl);
    colors = {
      bg: style.getPropertyValue("--color-bg").trim() || "#000",
      accent: style.getPropertyValue("--color-accent").trim() || "#f47b3f",
      hot: style.getPropertyValue("--color-text").trim() || "#fff"
    };
  }

  // Re-read the palette when the theme changes mid-session.
  $effect(() => {
    void theme;
    readColors();
  });

  onMount(() => {
    const canvas = canvasEl!;
    const wrap = wrapEl!;
    const ctx = canvas.getContext("2d")!;
    let raf = 0;
    let nextColumn = 0;
    const column = new Uint8Array(SPECTRO_BANDS);

    const handleFullscreenChange = () => {
      isFullscreen = document.fullscreenElement === wrap;
    };
    document.addEventListener("fullscreenchange", handleFullscreenChange);

    const dpr = () => Math.min(window.devicePixelRatio || 1, 2);
    const stepPx = () => Math.max(2, Math.round(2.4 * dpr()));

    function drawColumn(x: number, values: Uint8Array) {
      const height = canvas.height;
      const step = stepPx();
      const cell = height / SPECTRO_BANDS;
      const gap = Math.max(1, Math.floor(cell * 0.22));

      ctx.fillStyle = colors.bg;
      ctx.fillRect(x, 0, step, height);

      for (let band = 0; band < SPECTRO_BANDS; band += 1) {
        const value = values[band] / 255;
        if (value <= 0.02) {
          continue;
        }
        const y = height - (band + 1) * cell;
        ctx.globalAlpha = Math.pow(value, 1.4);
        ctx.fillStyle = value > 0.82 ? colors.hot : colors.accent;
        ctx.fillRect(x, y + gap / 2, step, Math.max(1, cell - gap));
      }
      ctx.globalAlpha = 1;
    }

    // Paint everything the sampler remembers, newest at the right edge —
    // this is what makes the view arrive "preloaded" instead of blank.
    function paintHistory() {
      readColors();
      const width = canvas.width;
      const step = stepPx();
      ctx.fillStyle = colors.bg;
      ctx.fillRect(0, 0, width, canvas.height);
      if (!sampler) {
        return;
      }
      const fits = Math.ceil(width / step);
      const end = sampler.count;
      const start = Math.max(sampler.oldestIndex, end - fits);
      for (let index = start; index < end; index += 1) {
        sampler.column(index, column);
        drawColumn(width - (end - index) * step, column);
      }
      nextColumn = end;
    }

    function resize() {
      const width = Math.max(1, Math.round(wrap.clientWidth * dpr()));
      const height = Math.max(1, Math.round(wrap.clientHeight * dpr()));
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
        paintHistory();
      }
    }

    const observer = new ResizeObserver(resize);
    observer.observe(wrap);
    resize();
    paintHistory();

    function draw() {
      raf = requestAnimationFrame(draw);
      if (!sampler) {
        return;
      }
      const width = canvas.width;
      const step = stepPx();
      const pending = sampler.count - nextColumn;
      if (pending <= 0) {
        return;
      }
      // A long gap (hidden tab) is cheaper to repaint than to scroll.
      if (pending > Math.ceil(width / step)) {
        paintHistory();
        return;
      }
      for (; nextColumn < sampler.count; nextColumn += 1) {
        ctx.drawImage(canvas, -step, 0);
        sampler.column(nextColumn, column);
        drawColumn(width - step, column);
      }
    }

    draw();

    return () => {
      cancelAnimationFrame(raf);
      observer.disconnect();
      document.removeEventListener("fullscreenchange", handleFullscreenChange);
    };
  });
</script>

<section class="visualizer-view" aria-label="Visualizer">
  <!-- svelte-ignore a11y_no_static_element_interactions -- double-click is a
       convenience duplicate of the fullscreen button, which is the
       accessible path. -->
  <div class="visualizer-stage" bind:this={wrapEl} ondblclick={toggleFullscreen}>
    <canvas bind:this={canvasEl}></canvas>
    <button
      class="visualizer-fullscreen"
      title={isFullscreen ? "Exit full screen" : "Full screen"}
      aria-label={isFullscreen ? "Exit full screen" : "Full screen"}
      type="button"
      onclick={toggleFullscreen}
    >
      {#if isFullscreen}
        <Minimize2 size={17} />
      {:else}
        <Maximize2 size={17} />
      {/if}
    </button>
    {#if !sampler}
      <p class="visualizer-note">The visualizer needs local playback — play a track on this device.</p>
    {:else if !currentTrack}
      <p class="visualizer-note">Play something to see it.</p>
    {/if}
  </div>
</section>
