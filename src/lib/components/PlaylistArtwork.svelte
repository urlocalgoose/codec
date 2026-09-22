<script lang="ts">
  import ArtworkImage from "./ArtworkImage.svelte";
  import { ListMusic } from "lucide-svelte";

  let { artworkUrl, covers = [] }: { artworkUrl?: string | null; covers?: readonly string[] } = $props();
  let failed = $state<string[]>([]);
  const usable = $derived(covers.filter((url) => !failed.includes(url)));
  const custom = $derived(artworkUrl && !failed.includes(artworkUrl) ? artworkUrl : null);
  const tiles = $derived(custom ? [custom] : usable.length > 1
    ? Array.from({ length: 4 }, (_, index) => usable[index % usable.length])
    : usable.slice(0, 1));
</script>

<span class="playlist-artwork" class:collage={tiles.length > 1} aria-hidden="true">
  {#each tiles as url, index (`${url}:${index}`)}
    <ArtworkImage src={url} alt="" loading="lazy" decoding="async" onerror={() => { failed = [...failed, url]; }} />
  {:else}
    <ListMusic size={40} strokeWidth={1.5} />
  {/each}
</span>
