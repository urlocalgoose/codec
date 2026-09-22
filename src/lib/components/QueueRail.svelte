<script lang="ts">
  import ArtworkImage from "./ArtworkImage.svelte";
  import VirtualRows from "./VirtualRows.svelte";
  import { ListMusic, Music2, Pause, Play, X } from "lucide-svelte";
  import { formatDuration } from "$lib/library";
  import type { Track } from "$lib/types";

  let {
    queue,
    queuedTracksCount,
    currentTrackId,
    isPlaying,
    onPlayQueueTrack,
    onRemoveQueued,
    onMoveQueued,
    onClearQueue
  }: {
    queue: Track[];
    queuedTracksCount: number;
    currentTrackId: string | null;
    isPlaying: boolean;
    onPlayQueueTrack: (index: number) => void;
    onRemoveQueued: (index: number) => void;
    onMoveQueued: (index: number, targetIndex: number) => void;
    onClearQueue: () => void;
  } = $props();

  let current = $derived(queue[0] ?? null);
  let upNext = $derived(queue.slice(1));
  let manualQueue = $derived(upNext.slice(0, queuedTracksCount));
  let upcomingQueue = $derived(upNext.slice(queuedTracksCount));
  let list: HTMLDivElement;
  let manualRows = $state<{ focusRow(index: number, selector: string): Promise<void> }>();
  let upcomingRows = $state<{ focusRow(index: number, selector: string): Promise<void> }>();

  function handleQueueTab(event: KeyboardEvent) {
    if (event.key !== "Tab" || event.altKey || event.ctrlKey || event.metaKey || !(event.target instanceof HTMLElement)) return;
    const row = event.target.closest<HTMLElement>("[data-queue-index]");
    if (!row) return;
    const index = Number(row.dataset.queueIndex);
    const remove = row.querySelector<HTMLButtonElement>(".queue-rail-remove");
    // Preserve both controls in a manual row's existing Tab order.
    if (remove && ((!event.shiftKey && event.target === row) || (event.shiftKey && event.target === remove))) {
      event.preventDefault();
      (event.shiftKey ? row : remove).focus();
      return;
    }
    const next = index + (event.shiftKey ? -1 : 1);
    if (next < 0 || next >= queue.length) return; // Leave the queue normally at its boundaries.
    event.preventDefault();
    if (next === 0) {
      list.querySelector<HTMLElement>('[data-queue-index="0"]')?.focus();
    } else if (next <= queuedTracksCount) {
      void manualRows?.focusRow(next - 1, event.shiftKey ? ".queue-rail-remove" : ".queue-rail-row");
    } else {
      void upcomingRows?.focusRow(next - queuedTracksCount - 1, ".queue-rail-row");
    }
  }

  function handleRowKeydown(event: KeyboardEvent, index: number) {
    if (event.key !== "Enter" && event.key !== " ") {
      return;
    }

    event.preventDefault();
    onPlayQueueTrack(index);
  }

  // Drag-to-reorder for the manual queue. Indices are queue positions
  // (offset by 1 for Now Playing), same convention as remove.
  let dragQueueIndex: number | null = $state(null);
  let dropQueueIndex: number | null = $state(null);

  function handleDragStart(event: DragEvent, queueIndex: number) {
    dragQueueIndex = queueIndex;
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", String(queueIndex));
    }
  }

  function handleDragOver(event: DragEvent, queueIndex: number) {
    if (dragQueueIndex === null) {
      return;
    }
    event.preventDefault();
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = "move";
    }
    dropQueueIndex = queueIndex;
  }

  function handleDrop(event: DragEvent, queueIndex: number) {
    event.preventDefault();
    if (dragQueueIndex !== null && dragQueueIndex !== queueIndex) {
      onMoveQueued(dragQueueIndex, queueIndex);
    }
    dragQueueIndex = null;
    dropQueueIndex = null;
  }

  function handleDragEnd() {
    dragQueueIndex = null;
    dropQueueIndex = null;
  }
</script>

<aside class="queue-rail" aria-label="Queue">
  <header class="queue-rail-header">
    <h2>Queue</h2>
    {#if queuedTracksCount > 0}
      <button
        class="queue-rail-clear"
        title="Clear queued tracks"
        aria-label="Clear queued tracks"
        type="button"
        onclick={onClearQueue}
      >
        Clear
      </button>
    {/if}
  </header>

  <div class="queue-rail-list" bind:this={list} onkeydown={handleQueueTab} role="presentation">
    {#if current}
      <section class="queue-rail-section" aria-label="Now Playing">
        <h3>Now Playing</h3>
        <button
          class="queue-rail-row queue-now"
          data-queue-index="0"
          class:active={currentTrackId === current.id}
          aria-label={isPlaying ? `Pause ${current.title}` : `Play ${current.title}`}
          type="button"
          onclick={() => onPlayQueueTrack(0)}
        >
          {#if current.artwork_url}
            <ArtworkImage class="queue-rail-art" src={current.artwork_url} alt="" loading="lazy" decoding="async" />
          {:else}
            <span class="queue-rail-art placeholder"><Music2 size={15} /></span>
          {/if}
          <div class="queue-rail-copy">
            <strong>{current.title}</strong>
            <span>{current.artist}</span>
          </div>
          <span class="queue-rail-state" aria-hidden="true">
            {#if isPlaying}
              <Pause size={15} />
            {:else}
              <Play size={15} />
            {/if}
          </span>
        </button>
      </section>
    {:else}
      <section class="queue-rail-empty">
        <ListMusic size={22} />
        <span>Nothing queued</span>
      </section>
    {/if}

    {#if manualQueue.length > 0}
      <section class="queue-rail-section" aria-label="In Queue">
        <h3>In Queue</h3>
        <VirtualRows items={manualQueue} rowHeight={58} bind:this={manualRows}>
          {#snippet children(track, offset)}
          {@const queueIndex = offset + 1}
          <div
            class="queue-rail-row queued"
            data-queue-index={queueIndex}
            class:dragging={dragQueueIndex === queueIndex}
            class:drop-target={dropQueueIndex === queueIndex && dragQueueIndex !== queueIndex}
            role="button"
            tabindex="0"
            draggable="true"
            aria-label={`Play ${track.title}. Drag to reorder.`}
            onclick={() => onPlayQueueTrack(queueIndex)}
            onkeydown={(event) => handleRowKeydown(event, queueIndex)}
            ondragstart={(event) => handleDragStart(event, queueIndex)}
            ondragover={(event) => handleDragOver(event, queueIndex)}
            ondrop={(event) => handleDrop(event, queueIndex)}
            ondragend={handleDragEnd}
          >
            {#if track.artwork_url}
              <ArtworkImage class="queue-rail-art" src={track.artwork_url} alt="" loading="lazy" decoding="async" />
            {:else}
              <span class="queue-rail-art placeholder"><Music2 size={15} /></span>
            {/if}
            <div class="queue-rail-copy">
              <strong>{track.title}</strong>
              <span>{track.artist}</span>
            </div>
            <span class="queue-rail-time">{formatDuration(track.duration_seconds)}</span>
            <button
              class="queue-rail-remove"
              title={`Remove ${track.title} from queue`}
              aria-label={`Remove ${track.title} from queue`}
              type="button"
              onclick={(event) => {
                event.stopPropagation();
                onRemoveQueued(queueIndex);
              }}
              onkeydown={(event) => { if (event.key !== "Tab") event.stopPropagation(); }}
            >
              <X size={14} />
            </button>
          </div>
          {/snippet}
        </VirtualRows>
      </section>
    {/if}

    {#if upcomingQueue.length > 0}
      <section class="queue-rail-section" aria-label="Up Next">
        <h3>Up Next</h3>
        <VirtualRows items={upcomingQueue} rowHeight={58} bind:this={upcomingRows}>
          {#snippet children(track, offset)}
          {@const queueIndex = queuedTracksCount + offset + 1}
          <div
            class="queue-rail-row"
            data-queue-index={queueIndex}
            role="button"
            tabindex="0"
            aria-label={`Play ${track.title}`}
            onclick={() => onPlayQueueTrack(queueIndex)}
            onkeydown={(event) => handleRowKeydown(event, queueIndex)}
          >
            {#if track.artwork_url}
              <ArtworkImage class="queue-rail-art" src={track.artwork_url} alt="" loading="lazy" decoding="async" />
            {:else}
              <span class="queue-rail-art placeholder"><Music2 size={15} /></span>
            {/if}
            <div class="queue-rail-copy">
              <strong>{track.title}</strong>
              <span>{track.artist}</span>
            </div>
            <span class="queue-rail-time">{formatDuration(track.duration_seconds)}</span>
            <span></span>
          </div>
          {/snippet}
        </VirtualRows>
      </section>
    {:else if current && manualQueue.length === 0}
      <p class="queue-rail-note">Pick tracks or shuffle a playlist.</p>
    {:else if !current}
      <p class="queue-rail-note">Queue a track to see it here.</p>
    {/if}
  </div>
</aside>
