<script lang="ts">
  import { ListMusic } from "lucide-svelte";
  import { formatCount } from "$lib/library";
  import type { Playlist, Track } from "$lib/types";

  let {
    playlists,
    playlistCovers,
    onOpen
  }: {
    playlists: Playlist[];
    playlistCovers: Map<string, Track | null>;
    onOpen: (playlistId: string) => void;
  } = $props();
</script>

<section class="summary-grid" aria-label="Playlists">
  {#each playlists as playlist (playlist.id)}
    {@const cover = playlistCovers.get(playlist.id)}
    <button class="summary-card" type="button" onclick={() => onOpen(playlist.id)}>
      {#if playlist.artwork_url}
        <img class="summary-art" src={playlist.artwork_url} alt="" loading="lazy" decoding="async" />
      {:else if cover?.artwork_url}
        <img class="summary-art" src={cover.artwork_url} alt="" loading="lazy" decoding="async" />
      {:else}
        <span class="summary-icon"><ListMusic size={48} /></span>
      {/if}
      <strong>{playlist.name}</strong>
      <span>{formatCount(playlist.track_ids.length, "song")}</span>
    </button>
  {/each}
  {#if playlists.length === 0}
    <p class="home-empty">No playlists yet.</p>
  {/if}
</section>
