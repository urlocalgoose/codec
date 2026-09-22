<script lang="ts">
  import { onMount, untrack } from "svelte";
  import { artworkIdentity, sampleArtwork, type ArtworkSample } from "$lib/artwork-atmosphere";

  let { artwork, theme, visible = true }: { artwork?: string | null; theme: string; visible?: boolean } = $props();
  let sample = $state<ArtworkSample | null>(null);
  let light = $state(false);
  let active = $state(true);
  let surface = $state<HTMLDivElement>();
  // Playback refreshes replace track objects and rotate stream credentials.
  // Only a different artwork identity should restart the atmosphere cycle.
  const identity = $derived(artworkIdentity(artwork ?? ""));

  $effect(() => {
    const key = identity;
    const url = untrack(() => artwork);
    let cancelled = false;
    if (!url || !key) sample = null;
    else void sampleArtwork(url, key).then((value) => { if (!cancelled) sample = value; });
    return () => { cancelled = true; };
  });

  $effect(() => {
    void theme;
    if (!surface) return;
    const rgb = getComputedStyle(surface).getPropertyValue("--color-bg").trim();
    const channels = /^#[\da-f]{6}$/i.test(rgb)
      ? [1, 3, 5].map((index) => parseInt(rgb.slice(index, index + 2), 16))
      : (rgb.match(/[\d.]+/g) ?? []).slice(0, 3).map(Number);
    light = channels.length === 3 && (channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722) / 255 > .5;
  });

  onMount(() => {
    const changed = () => { active = document.visibilityState === "visible"; };
    changed();
    document.addEventListener("visibilitychange", changed);
    return () => document.removeEventListener("visibilitychange", changed);
  });
</script>

<div class="artwork-atmosphere" class:light class:atmosphere-paused={!visible || !active} bind:this={surface} aria-hidden="true">
  {#if sample}
    {#key sample}
      <div class="atmosphere-layers" style={`--art-warm:${sample.warm};--art-cool:${sample.cool};--art-deep:${sample.deep}`}>
        <div class="atmosphere-surface atmosphere-halo"><div></div></div>
        <div class="atmosphere-surface atmosphere-wash"><div></div><span></span></div>
        <div class="atmosphere-surface atmosphere-immersive"><img src={sample.blurred} alt="" /><span></span></div>
      </div>
    {/key}
  {/if}
</div>
