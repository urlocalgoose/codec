<script lang="ts">
  import { Check, X } from "lucide-svelte";
  import { formatCount } from "$lib/library";
  import type { Playlist, Track } from "$lib/types";

  let {
    track,
    playlists,
    selectedIds = $bindable(),
    saving,
    onClose,
    onSave
  }: {
    track: Track;
    playlists: Playlist[];
    selectedIds: string[];
    saving: boolean;
    onClose: () => void;
    onSave: () => void;
  } = $props();

  function togglePlaylist(playlistId: string, checked: boolean) {
    if (checked) {
      if (!selectedIds.includes(playlistId)) {
        selectedIds = [...selectedIds, playlistId];
      }
    } else {
      selectedIds = selectedIds.filter((id) => id !== playlistId);
    }
  }

  function handleBackdropClick(event: MouseEvent) {
    if (event.target === event.currentTarget) {
      onClose();
    }
  }
</script>

<div
  class="modal-backdrop"
  role="presentation"
  onclick={handleBackdropClick}
>
  <div
    class="app-modal playlist-modal"
    role="dialog"
    aria-label={`Edit playlists for ${track.title}`}
    aria-modal="true"
  >
    <header class="modal-header">
      <div>
        <span>Playlists</span>
        <h2>{track.title}</h2>
        <p>{track.artist}</p>
      </div>
      <button
        class="title-icon-button"
        title="Close"
        aria-label="Close playlist editor"
        type="button"
        onclick={onClose}
      >
        <X size={18} />
      </button>
    </header>

    <div class="playlist-choice-list">
      {#each playlists as playlist (playlist.id)}
        {@const playlistSelected = selectedIds.includes(playlist.id)}
        <label class="playlist-choice" class:active={playlistSelected}>
          <input
            checked={playlistSelected}
            type="checkbox"
            value={playlist.id}
            onchange={(event) => togglePlaylist(playlist.id, event.currentTarget.checked)}
          />
          <span class="choice-box">
            {#if playlistSelected}
              <Check size={15} />
            {/if}
          </span>
          <span class="choice-copy">
            <strong>{playlist.is_liked ? "Liked Songs" : playlist.name}</strong>
            <small>{formatCount(playlist.track_ids.length, "track")}</small>
          </span>
        </label>
      {/each}
    </div>

    <footer class="modal-actions">
      <button class="ui-button compact" type="button" onclick={onClose}>
        Cancel
      </button>
      <button
        class="ui-button primary compact"
        disabled={saving}
        type="button"
        onclick={onSave}
      >
        {saving ? "Saving" : "Save"}
      </button>
    </footer>
  </div>
</div>
