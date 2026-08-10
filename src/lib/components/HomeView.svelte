<script lang="ts">
  import { Disc3, ListMusic, Music2, Play } from "lucide-svelte";
  import { formatCount } from "$lib/library";
  import type { HomeRecentItem } from "$lib/library";
  import type { Playlist, Track } from "$lib/types";

  let {
    userPlaylists,
    recentItems,
    playlistCovers,
    currentTrackId,
    onOpenPlaylist,
    onOpenAlbum,
    onPlayTrack
  }: {
    userPlaylists: Playlist[];
    recentItems: HomeRecentItem[];
    playlistCovers: Map<string, Track | null>;
    currentTrackId: string | null;
    onOpenPlaylist: (playlistId: string) => void;
    onOpenAlbum: (albumName: string) => void;
    onPlayTrack: (track: Track) => void;
  } = $props();
</script>

<section class="home-view" aria-label="Home">
  <h1 class="home-wordmark">Codec</h1>

  {#if userPlaylists.length > 0}
    <div class="home-section">
      <h2 class="home-section-label">Playlists</h2>
      <div class="home-playlist-row">
        {#each userPlaylists as playlist (playlist.id)}
          {@const cover = playlistCovers.get(playlist.id)}
          <button class="home-playlist-card" type="button" onclick={() => onOpenPlaylist(playlist.id)}>
            {#if cover?.artwork_url}
              <img class="home-card-art" src={cover.artwork_url} alt="" loading="lazy" decoding="async" />
            {:else}
              <span class="home-card-art placeholder"><ListMusic size={26} /></span>
            {/if}
            <strong>{playlist.name}</strong>
            <span>{formatCount(playlist.track_ids.length, "song")}</span>
          </button>
        {/each}
      </div>
    </div>
  {/if}

  <div class="home-section">
    <h2 class="home-section-label">Recently added</h2>
    {#if recentItems.length > 0}
      <div class="home-recent-grid">
        {#each recentItems as item (item.kind === "album" ? `album:${item.album.artist}|${item.album.name}` : `track:${item.track.id}`)}
          {#if item.kind === "album"}
            <button class="home-tile" type="button" onclick={() => onOpenAlbum(item.album.name)}>
              {#if item.cover.artwork_url}
                <img class="home-tile-art" src={item.cover.artwork_url} alt="" loading="lazy" decoding="async" />
              {:else}
                <span class="home-tile-art placeholder"><Disc3 size={30} /></span>
              {/if}
              <strong>{item.album.name}</strong>
              <span>{item.album.artist}</span>
            </button>
          {:else}
            <button
              class="home-tile"
              class:playing={currentTrackId === item.track.id}
              type="button"
              onclick={() => onPlayTrack(item.track)}
            >
              {#if item.track.artwork_url}
                <img class="home-tile-art" src={item.track.artwork_url} alt="" loading="lazy" decoding="async" />
              {:else}
                <span class="home-tile-art placeholder"><Music2 size={30} /></span>
              {/if}
              <span class="home-tile-play"><Play size={16} /></span>
              <strong>{item.track.title}</strong>
              <span>{item.track.artist}</span>
            </button>
          {/if}
        {/each}
      </div>
    {:else}
      <p class="home-empty">Nothing here yet — import some music.</p>
    {/if}
  </div>
</section>
