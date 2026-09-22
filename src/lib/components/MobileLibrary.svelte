<script lang="ts">
  import { ChevronRight, CircleArrowDown, Heart, ListMusic, Music2, Plus, Trash2 } from "lucide-svelte";
  import PlaylistArtwork from "./PlaylistArtwork.svelte";
  import VirtualRows from "./VirtualRows.svelte";
  import MobileSwipeRow from "./MobileSwipeRow.svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import MobileDeletePlaylist from "./MobileDeletePlaylist.svelte";
  import { formatCount } from "$lib/library";
  import type { AlbumSummary, ArtistSummary, Playlist } from "$lib/types";

  let { playlists, playlistArtwork, songCount, likedCount, downloadedCount = 0, canCreate,
    onOpen, onOpenDownloaded, onCreate, onDelete }: {
    playlists: Playlist[];
    playlistArtwork: Map<string, readonly string[]>;
    songCount: number;
    likedCount: number;
    downloadedCount?: number;
    canCreate: boolean;
    onOpen: (view: string) => void;
    onOpenDownloaded?: () => void;
    onCreate: () => void;
    onDelete?: (playlist: Playlist) => Promise<void>;
    // Accepted while the shared page still passes desktop browse data.
    albums?: AlbumSummary[];
    artists?: ArtistSummary[];
    onOpenAlbum?: (album: AlbumSummary) => void;
    onOpenArtist?: (artist: ArtistSummary) => void;
  } = $props();
  let openPlaylistID = $state("");
  let menuPlaylistID = $state("");
  let deletePlaylistID = $state("");
  const menuPlaylist = $derived(playlists.find(playlist => playlist.id === menuPlaylistID));
  const deletePlaylist = $derived(playlists.find(playlist => playlist.id === deletePlaylistID));

  function canDelete(playlist: Playlist) { return canCreate && Boolean(onDelete) && !playlist.is_liked; }
  function requestDelete(playlist: Playlist) {
    if (!canDelete(playlist)) return;
    openPlaylistID = "";
    menuPlaylistID = "";
    deletePlaylistID = playlist.id;
  }
  async function confirmDelete(playlist: Playlist) {
    const current = playlists.find(candidate => candidate.id === playlist.id);
    if (!current || !canDelete(current) || !onDelete) throw new Error("This playlist is no longer available to delete.");
    await onDelete(current);
  }
  function focusPlaylist(id: string) {
    const row = Array.from(document.querySelectorAll<HTMLButtonElement>(".mobile-playlist-row[data-playlist-id]"))
      .find(button => button.dataset.playlistId === id);
    row?.focus({ preventScroll: true });
  }
  $effect(() => {
    if (!canCreate || !onDelete) {
      openPlaylistID = "";
      menuPlaylistID = "";
      deletePlaylistID = "";
    } else {
      if (openPlaylistID && !playlists.some(playlist => playlist.id === openPlaylistID && !playlist.is_liked)) openPlaylistID = "";
      if (menuPlaylistID && !menuPlaylist) menuPlaylistID = "";
      if (deletePlaylistID && !deletePlaylist) deletePlaylistID = "";
    }
  });
</script>

<section class="mobile-library native-library" aria-label="Library">
  <h1 class="mobile-large-title mobile-library-title">Library</h1>
  <section class="mobile-library-section" aria-label="Playlists">
    <div class="mobile-section-heading">
      <h2>Playlists</h2>
      {#if canCreate}<button class="mobile-icon-button" aria-label="New playlist" type="button" onclick={onCreate}><Plus size={18} /></button>{/if}
    </div>
    {#if playlists.length}
      <div class="mobile-library-group mobile-playlist-list">
        <VirtualRows items={playlists} rowHeight={64}>
          {#snippet children(playlist, index)}
          <MobileSwipeRow identity={playlist.id} leading={[]}
            trailing={canDelete(playlist) ? [{ id: "delete", label: "Delete", ariaLabel: `Delete playlist ${playlist.name}`, icon: "delete", tone: "danger", run: () => requestDelete(playlist) }] : []}
            openSide={openPlaylistID === playlist.id ? "trailing" : null}
            onOpenChange={(side) => { if (side) openPlaylistID = playlist.id; else if (openPlaylistID === playlist.id) openPlaylistID = ""; }}
            allowTrailingFull={false}
            onLongPress={canDelete(playlist) ? () => { openPlaylistID = ""; menuPlaylistID = playlist.id; } : undefined}>
          <button class="mobile-playlist-row" data-playlist-id={playlist.id} class:last-playlist-row={index === playlists.length - 1} type="button" onclick={() => onOpen(playlist.id)}>
            <PlaylistArtwork artworkUrl={playlist.artwork_url} covers={playlistArtwork.get(playlist.id)} />
            <span class="mobile-library-row-copy"><strong>{playlist.name}</strong><small>{formatCount(playlist.track_ids.length, "song")}</small></span>
            <ChevronRight size={13} strokeWidth={2.5} />
          </button>
          </MobileSwipeRow>
          {/snippet}
        </VirtualRows>
      </div>
    {:else}
      <div class="mobile-library-group">
        {#if canCreate}
          <button class="mobile-library-empty-action" type="button" onclick={onCreate}><ListMusic size={21} /><strong>Make your first playlist</strong></button>
        {:else}
          <div class="mobile-library-empty-row"><ListMusic size={21} /><strong>No playlists</strong></div>
        {/if}
      </div>
    {/if}
  </section>
  <div class="mobile-library-group mobile-music-group" aria-label="Your music">
    <button type="button" onclick={() => onOpen("liked")}><Heart size={20} fill="currentColor" /><strong>Liked Songs</strong><span>{likedCount}</span><ChevronRight size={13} strokeWidth={2.5} /></button>
    <button type="button" onclick={() => onOpen("all")}><Music2 size={20} /><strong>Songs</strong><span>{songCount}</span><ChevronRight size={13} strokeWidth={2.5} /></button>
    {#if onOpenDownloaded}
      <button type="button" onclick={onOpenDownloaded}><CircleArrowDown class="native-download-icon" size={20} /><strong>Downloaded</strong><span>{downloadedCount}</span><ChevronRight size={13} strokeWidth={2.5} /></button>
    {/if}
  </div>
</section>

{#if menuPlaylist && canDelete(menuPlaylist)}
  <MobileSheet title={menuPlaylist.name} onClose={() => { menuPlaylistID = ""; }} compact>
    <div class="mobile-track-actions">
      <button type="button" onclick={() => { if (menuPlaylist) requestDelete(menuPlaylist); }}><Trash2 size={21} />Delete Playlist</button>
    </div>
  </MobileSheet>
{/if}
{#if deletePlaylist && canDelete(deletePlaylist)}
  <MobileDeletePlaylist playlist={deletePlaylist} onDelete={confirmDelete} onClose={() => { deletePlaylistID = ""; }} returnFocus={focusPlaylist} />
{/if}
