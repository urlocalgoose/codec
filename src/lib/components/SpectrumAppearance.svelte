<script lang="ts">
  import { untrack } from "svelte";
  import type { Track } from "$lib/types";
  import type { SpectroSampler } from "$lib/visualizer";
  import { artworkIdentity, sampleArtwork } from "$lib/artwork-atmosphere";
  import { readSpectrumTheme, spectrumColorTable, spectrumPalette } from "$lib/visualizer-palette";

  let { sampler, currentTrack, theme }: { sampler: SpectroSampler; currentTrack: Track | null; theme: string } = $props();
  let surface: HTMLSpanElement | undefined = $state();
  const identity = $derived(`${currentTrack?.id ?? ""}:${artworkIdentity(currentTrack?.artwork_url ?? "")}`);

  // This observer lives with playback, not with the visualizer tab. Columns
  // recorded while browsing Home/Library receive their own song's colors too.
  $effect(() => {
    void theme;
    void identity;
    if (!surface) return;
    const target = sampler;
    const tokens = readSpectrumTheme(surface);
    const url = untrack(() => currentTrack?.artwork_url);
    let cancelled = false;
    target.setColors(spectrumColorTable(spectrumPalette(tokens, null)));
    if (url) void sampleArtwork(url, artworkIdentity(url)).then(sample => {
      if (!cancelled) target.setColors(spectrumColorTable(spectrumPalette(tokens, sample)));
    });
    return () => { cancelled = true; };
  });
</script>

<span hidden aria-hidden="true" bind:this={surface}></span>
