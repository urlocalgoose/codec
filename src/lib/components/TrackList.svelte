<script lang="ts">
  import { ListPlus, Music2, Play, Shuffle, X } from "lucide-svelte";
  import { formatDuration } from "$lib/library";
  import type { SortKey, Track } from "$lib/types";

  let {
    viewTitle,
    isQueueView,
    listMeta,
    visibleTracks,
    queuedTracksCount,
    currentTrackId,
    isPlaying,
    sortKey,
    onSetSort,
    onPlayAll,
    onShuffleAll,
    onClearQueue,
    onPlayRow,
    onRemoveQueued,
    onEditPlaylists
  }: {
    viewTitle: string;
    isQueueView: boolean;
    listMeta: string;
    visibleTracks: Track[];
    queuedTracksCount: number;
    currentTrackId: string | null;
    isPlaying: boolean;
    sortKey: SortKey;
    onSetSort: (key: SortKey) => void;
    onPlayAll: () => void;
    onShuffleAll: () => void;
    onClearQueue: () => void;
    onPlayRow: (track: Track, index: number) => void;
    onRemoveQueued: (index: number) => void;
    onEditPlaylists: (track: Track) => void;
  } = $props();

  function handleRowKeydown(event: KeyboardEvent, track: Track, index: number) {
    if (event.key !== "Enter" && event.key !== " ") {
      return;
    }

    event.preventDefault();
    onPlayRow(track, index);
  }
</script>

<section class="track-surface" aria-label="Tracks">
  <div class="list-toolbar" aria-label={`${viewTitle} actions`}>
    <div class="list-meta">
      <span>{listMeta}</span>
    </div>
    <div class="list-actions">
      {#if isQueueView}
        <button
          class="ui-button compact"
          disabled={queuedTracksCount === 0}
          type="button"
          onclick={onClearQueue}
        >
          Clear
        </button>
      {:else}
        <button
          class="ui-button primary compact"
          disabled={visibleTracks.length === 0}
          type="button"
          onclick={onPlayAll}
        >
          <Play size={16} />
          Play
        </button>
        <button
          class="ui-button compact"
          disabled={visibleTracks.length === 0}
          type="button"
          onclick={onShuffleAll}
        >
          <Shuffle size={16} />
          Shuffle
        </button>
      {/if}
    </div>
  </div>
  {#if visibleTracks.length > 0}
    <div class="track-table">
      <div class="track-head">
        <button
          class:active={sortKey === "title"}
          type="button"
          onclick={() => onSetSort("title")}
        >
          Song
        </button>
        <button
          class:active={sortKey === "album"}
          type="button"
          onclick={() => onSetSort("album")}
        >
          Album
        </button>
        <button
          class:active={sortKey === "duration"}
          type="button"
          onclick={() => onSetSort("duration")}
        >
          Time
        </button>
        <span></span>
      </div>

      {#each visibleTracks as track, index (track.id)}
        <div
          class="track-row"
          class:active={currentTrackId === track.id}
          role="button"
          tabindex="0"
          aria-label={currentTrackId === track.id && isPlaying ? `Pause ${track.title}` : `Play ${track.title}`}
          onclick={() => onPlayRow(track, index)}
          onkeydown={(event) => handleRowKeydown(event, track, index)}
        >
          <div class="track-title-cell">
            {#if track.artwork_url}
              <img class="artwork" src={track.artwork_url} alt="" loading="lazy" decoding="async" />
            {:else}
              <span class="artwork placeholder"><Music2 size={18} /></span>
            {/if}
            <div>
              <strong>{track.title}</strong>
              <span>{track.artist}</span>
            </div>
          </div>

          <span class="table-album">{track.album}</span>
          <span class="table-duration">{formatDuration(track.duration_seconds)}</span>
          {#if isQueueView}
            {#if index > 0 && index <= queuedTracksCount}
              <button
                class="queue-button"
                title={`Remove ${track.title} from queue`}
                aria-label={`Remove ${track.title} from queue`}
                type="button"
                onclick={(event) => {
                  event.stopPropagation();
                  onRemoveQueued(index);
                }}
              >
                <X size={17} />
              </button>
            {:else}
              <span></span>
            {/if}
          {:else}
            <button
              class="queue-button"
              title={`Edit playlists for ${track.title}`}
              aria-label={`Edit playlists for ${track.title}`}
              type="button"
              onclick={(event) => {
                event.stopPropagation();
                onEditPlaylists(track);
              }}
            >
              <ListPlus size={17} />
            </button>
          {/if}
        </div>
      {/each}
    </div>
  {:else}
    <div class="empty-state">
      <Music2 size={32} />
      <p>No tracks here.</p>
    </div>
  {/if}
</section>
