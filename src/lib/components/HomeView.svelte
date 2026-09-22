<script lang="ts">
  import ArtworkImage from "./ArtworkImage.svelte";
  import PlaylistArtwork from "./PlaylistArtwork.svelte";
  import { AudioLines, ChevronRight, Disc3, ListMusic, Music2, Play, Radio } from "lucide-svelte";
  import { formatCount } from "$lib/library";
  import type { HomeRecentItem } from "$lib/library";
  import type { Playlist, Track } from "$lib/types";

  let {
    userPlaylists,
    recentItems,
    playlistCovers,
    currentTrackId,
    playingPlaylist = null,
    playingPlaylistCovers = [],
    isPlaying = false,
    onOpenPlaylist,
    onOpenAlbum,
    onPlayTrack,
    auxCode = "",
    onShowAux
  }: {
    userPlaylists: Playlist[];
    recentItems: HomeRecentItem[];
    playlistCovers: Map<string, Track | null>;
    currentTrackId: string | null;
    playingPlaylist?: Playlist | null;
    playingPlaylistCovers?: readonly string[];
    isPlaying?: boolean;
    onOpenPlaylist: (playlistId: string) => void;
    onOpenAlbum: (albumName: string, artist?: string) => void;
    onPlayTrack: (track: Track) => void;
    auxCode?: string;
    onShowAux?: () => void;
  } = $props();
</script>

<section class="home-view" aria-label="Home">
  <div class="home-heading"><h1 class="home-wordmark">Codec</h1>
    {#if auxCode}<button class="mobile-aux-chip" type="button" onclick={onShowAux}><Radio size={14} />{auxCode}</button>{/if}
  </div>

  {#if playingPlaylist}
    <button class="home-playing-source" type="button" onclick={() => onOpenPlaylist(playingPlaylist!.id)}
      aria-label={`${isPlaying ? "Playing from" : "Paused from"} ${playingPlaylist.name}. Open playlist`}>
      <PlaylistArtwork artworkUrl={playingPlaylist.artwork_url} covers={playingPlaylistCovers} />
      <span class="home-playing-copy">
        <span class="home-playing-label">{isPlaying ? "Playing from" : "Paused from"}</span>
        <strong>{playingPlaylist.name}</strong>
      </span>
      <ChevronRight size={13} strokeWidth={2} aria-hidden="true" />
    </button>
  {/if}

  {#if userPlaylists.length > 0}
    <div class="home-section">
      <h2 class="home-section-label">Playlists</h2>
      <div class="home-playlist-row">
        {#each userPlaylists as playlist (playlist.id)}
          {@const cover = playlistCovers.get(playlist.id)}
          <button class="home-playlist-card" type="button" onclick={() => onOpenPlaylist(playlist.id)}>
            {#if playlist.artwork_url}
              <ArtworkImage class="home-card-art" src={playlist.artwork_url} alt="" loading="lazy" decoding="async" />
            {:else if cover?.artwork_url}
              <ArtworkImage class="home-card-art" src={cover.artwork_url} alt="" loading="lazy" decoding="async" />
            {:else}
              <span class="home-card-art placeholder"><ListMusic class="desktop-home-placeholder" size={44} /><Music2 class="native-home-placeholder" size={44} /></span>
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
            <button class="home-tile" type="button" onclick={() => onOpenAlbum(item.album.name, item.album.artist)}>
              {#if item.cover.artwork_url}
                <ArtworkImage class="home-tile-art" src={item.cover.artwork_url} alt="" loading="lazy" decoding="async" />
              {:else}
                <span class="home-tile-art placeholder"><Disc3 class="desktop-home-placeholder" size={44} /><Music2 class="native-home-placeholder" size={44} /></span>
              {/if}
              <span class="home-tile-caption"><span class="home-tile-copy">
                <strong>{item.album.name}</strong>
                <span><span class="mobile-only">Album · </span>{item.album.artist}</span>
              </span></span>
            </button>
          {:else}
            <button
              class="home-tile"
              class:playing={currentTrackId === item.track.id}
              type="button"
              onclick={() => onPlayTrack(item.track)}
            >
              <span class="home-tile-cover">
                {#if item.track.artwork_url}
                  <ArtworkImage class="home-tile-art" src={item.track.artwork_url} alt="" loading="lazy" decoding="async" />
                {:else}
                  <span class="home-tile-art placeholder"><Music2 size={44} /></span>
                {/if}
                <span class="home-tile-play"><Play size={16} /></span>
              </span>
              <span class="home-tile-caption">
                {#if currentTrackId === item.track.id}<AudioLines class="home-tile-current" size={12} aria-hidden="true" />{/if}
                <span class="home-tile-copy"><strong>{item.track.title}</strong><span>{item.track.artist}</span></span>
              </span>
            </button>
          {/if}
        {/each}
      </div>
    {:else}
      <p class="home-empty">Nothing here yet — import some music.</p>
    {/if}
  </div>
</section>

<style>
  .home-playing-source {
    display: flex; align-items: center; gap: 12px; width: 100%; min-width: 0;
    padding: 12px; border: 0; border-radius: 20px;
    background: var(--color-panel); color: var(--color-text);
    font: inherit; text-align: start; cursor: pointer;
    transition: transform 150ms cubic-bezier(0.2, 0, 0, 1);
  }
  .home-playing-source:hover { background: var(--color-panel-2); }
  .home-playing-source:active { transform: scale(0.96); }
  .home-playing-source:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 3px; }
  .home-playing-source :global(.playlist-artwork) {
    width: 44px; height: 44px; flex: 0 0 44px; object-fit: cover; border-radius: 8px;
  }
  .home-playing-source :global(.playlist-artwork > svg) { width: 14px; height: 14px; }
  .home-playing-copy { display: grid; gap: 3px; flex: 1; min-width: 0; }
  .home-playing-label { font-size: 11px; font-weight: 600; line-height: 14px; color: var(--color-subtle); }
  .home-playing-copy strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 15px; font-weight: 600; line-height: 18px; }
  .home-playing-source > :global(svg) { flex-shrink: 0; color: var(--color-subtle); }
  @media (prefers-reduced-motion: reduce) { .home-playing-source { transition: none; } .home-playing-source:active { transform: none; } }
</style>
