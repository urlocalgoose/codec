<script lang="ts">
  import { onMount } from "svelte";
  import { Maximize2, Minimize2 } from "lucide-svelte";
  import { SPECTRO_BANDS, type SpectroSampler } from "$lib/visualizer";
  import type { Track } from "$lib/types";
  import { readSpectrumTheme, spectrumPalette, spectrumColorTable, type SpectrumColors } from "$lib/visualizer-palette";

  let {
    sampler,
    currentTrack,
    theme,
    sampling = true
  }: {
    sampler: SpectroSampler | null;
    currentTrack: Track | null;
    theme: string;
    sampling?: boolean;
  } = $props();

  let wrapEl: HTMLDivElement | undefined = $state();
  let canvasEl: HTMLCanvasElement | undefined = $state();
  let isFullscreen = $state(false);
  let expanded = $state(false);

  function toggleFullscreen() {
    if (document.fullscreenElement) {
      void document.exitFullscreen();
    } else if (expanded) {
      expanded = false;
      isFullscreen = false;
    } else if (wrapEl) {
      const expandInPage = () => { expanded = true; isFullscreen = true; };
      // iPhone browsers may not expose fullscreen for arbitrary elements.
      // The viewport-sized view keeps the same control available there.
      if (typeof wrapEl.requestFullscreen !== "function") expandInPage();
      else void wrapEl.requestFullscreen().catch(expandInPage);
    }
  }

  let repaint: (() => void) | undefined = $state();
  let updateSampling: (() => void) | undefined;
  $effect(() => { void sampling; updateSampling?.(); });

  // Redraws may resize or expose more history; they never apply today's
  // palette to yesterday's columns. Their recorded inks/background stay fixed.
  $effect(() => {
    void theme;
    const paint = repaint;
    paint?.();
    if (sampler && paint) return sampler.subscribeColors(paint);
  });

  onMount(() => {
    const canvas = canvasEl!;
    const wrap = wrapEl!;
    const ctx = canvas.getContext("2d")!;
    let raf = 0;
    let nextColumn = 0;
    const column = new Uint8Array(SPECTRO_BANDS);

    const handleFullscreenChange = () => {
      isFullscreen = expanded || document.fullscreenElement === wrap;
    };
    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape" && expanded) { expanded = false; isFullscreen = false; }
    };
    document.addEventListener("fullscreenchange", handleFullscreenChange);
    document.addEventListener("keydown", handleEscape);

    const dpr = () => Math.min(window.devicePixelRatio || 1, 2);
    const stepPx = () => Math.max(2, Math.round(2.4 * dpr()));

    function drawColumn(x: number, values: Uint8Array, colors: SpectrumColors) {
      const height = canvas.height;
      const step = stepPx();
      const cell = height / SPECTRO_BANDS;
      const gap = Math.max(1, Math.floor(cell * 0.22));

      ctx.fillStyle = colors.background;
      ctx.fillRect(x, 0, step, height);

      for (let band = 0; band < SPECTRO_BANDS; band += 1) {
        const value = values[band] / 255;
        if (value <= 0.02) {
          continue;
        }
        const y = height - (band + 1) * cell;
        ctx.globalAlpha = colors.alpha[values[band]];
        ctx.fillStyle = colors.ink[values[band]];
        ctx.fillRect(x, y + gap / 2, step, Math.max(1, cell - gap));
      }
      ctx.globalAlpha = 1;
    }

    // Paint everything the sampler remembers, newest at the right edge —
    // this is what makes the view arrive "preloaded" instead of blank.
    function paintHistory() {
      const width = canvas.width;
      const step = stepPx();
      ctx.fillStyle = sampler?.currentColors.background
        ?? spectrumColorTable(spectrumPalette(readSpectrumTheme(wrap), null)).background;
      ctx.fillRect(0, 0, width, canvas.height);
      if (!sampler) {
        return;
      }
      const fits = Math.ceil(width / step);
      const end = sampler.count;
      const start = Math.max(sampler.oldestIndex, end - fits);
      for (let index = start; index < end; index += 1) {
        sampler.column(index, column);
        drawColumn(width - (end - index) * step, column, sampler.colorsAt(index));
      }
      nextColumn = end;
    }
    repaint = paintHistory;

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
      raf = 0;
      if (!sampling || document.hidden) return;
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
      if (nextColumn < sampler.oldestIndex || pending > Math.ceil(width / step)) {
        paintHistory();
        return;
      }
      for (; nextColumn < sampler.count; nextColumn += 1) {
        ctx.drawImage(canvas, -step, 0);
        sampler.column(nextColumn, column);
        drawColumn(width - step, column, sampler.colorsAt(nextColumn));
      }
    }

    function syncDrawing() {
      cancelAnimationFrame(raf);
      raf = 0;
      if (sampling && !document.hidden) {
        paintHistory();
        draw();
      }
    }
    updateSampling = syncDrawing;
    document.addEventListener("visibilitychange", syncDrawing);
    syncDrawing();

    return () => {
      repaint = undefined;
      updateSampling = undefined;
      document.removeEventListener("visibilitychange", syncDrawing);
      cancelAnimationFrame(raf);
      observer.disconnect();
      document.removeEventListener("fullscreenchange", handleFullscreenChange);
      document.removeEventListener("keydown", handleEscape);
    };
  });
</script>

<section class="visualizer-view" aria-label="Visualizer">
  <!-- svelte-ignore a11y_no_static_element_interactions -- double-click is a
       convenience duplicate of the fullscreen button, which is the
       accessible path. -->
  <div class="visualizer-stage" class:expanded bind:this={wrapEl} ondblclick={toggleFullscreen}>
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
