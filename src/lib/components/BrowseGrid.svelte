<script lang="ts">
  import { Disc3, Users } from "lucide-svelte";
  import { formatCount } from "$lib/library";
  import type { AlbumSummary, ArtistSummary } from "$lib/types";

  let {
    kind,
    artists = [],
    albums = [],
    onOpen
  }: {
    kind: "artists" | "albums";
    artists?: ArtistSummary[];
    albums?: AlbumSummary[];
    onOpen: (searchQuery: string) => void;
  } = $props();
</script>

{#if kind === "artists"}
  <section class="summary-grid artists-grid" aria-label="Artists">
    {#each artists as artist (artist.name)}
      <button class="summary-card" type="button" onclick={() => onOpen(artist.name)}>
        <span class="summary-icon"><Users size={22} /></span>
        <strong>{artist.name}</strong>
        <span>{formatCount(artist.trackCount, "track")} · {formatCount(artist.albumCount, "album")}</span>
      </button>
    {/each}
  </section>
{:else}
  <section class="summary-grid" aria-label="Albums">
    {#each albums as album (`${album.artist}-${album.name}`)}
      <button class="summary-card album-card" type="button" onclick={() => onOpen(album.name)}>
        {#if album.artwork_url}
          <img class="summary-art" src={album.artwork_url} alt="" loading="lazy" decoding="async" />
        {:else}
          <span class="summary-icon"><Disc3 size={24} /></span>
        {/if}
        <strong>{album.name}</strong>
        <span>{album.artist} · {formatCount(album.trackCount, "track")}</span>
      </button>
    {/each}
  </section>
{/if}
