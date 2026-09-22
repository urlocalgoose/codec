<script lang="ts">
  import ArtworkImage from "./ArtworkImage.svelte";
  import { onMount, tick } from "svelte";
  import { ArrowDownToLine, AudioLines, Check, CircleArrowDown, CircleMinus, Ellipsis, GripHorizontal, Heart, ListEnd, ListPlus, ListStart, LoaderCircle, Music2, Pause, Play, Shuffle, Trash2, X } from "lucide-svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import { formatDuration } from "$lib/library";
  import type { SortKey, Track } from "$lib/types";

  const INITIAL_RENDER_ROWS = 40;
  const OVERSCAN_ROWS = 8;

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
    onQueueTrack,
    onRemoveQueued,
    onEditPlaylists,
    onToggleLike,
    guestMode = false,
    downloadedIDs = new Set<string>(),
    downloadingIDs = new Set<string>(),
    onQueueNext,
    onDownloadTrack,
    onRemoveDownload,
    onDownloadAll,
    playlistEditing = false,
    onMovePlaylistTrack,
    onRemovePlaylistTrack,
    emptyTitle = "No Tracks",
    emptyDescription = ""
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
    onQueueTrack: (track: Track) => void;
    onRemoveQueued: (index: number) => void;
    onEditPlaylists: (track: Track) => void;
    onToggleLike: (track: Track) => void;
    guestMode?: boolean;
    downloadedIDs?: Set<string>;
    downloadingIDs?: Set<string>;
    onQueueNext?: (track: Track) => void;
    onDownloadTrack?: (track: Track) => void;
    onRemoveDownload?: (track: Track) => void;
    onDownloadAll?: () => void;
    playlistEditing?: boolean;
    onMovePlaylistTrack?: (from: number, to: number) => void;
    onRemovePlaylistTrack?: (index: number) => void;
    emptyTitle?: string;
    emptyDescription?: string;
  } = $props();

  const collectionDownloaded = $derived(visibleTracks.length > 0 && visibleTracks.every((track) => downloadedIDs.has(track.id)));
  const collectionDownloading = $derived(visibleTracks.some((track) => downloadingIDs.has(track.id)));
  let pressTimer: ReturnType<typeof setTimeout> | undefined;
  let pressOrigin = { x: 0, y: 0 };
  let suppressClickUntil = 0;
  let draggingIndex = $state<number | null>(null);
  let dragTarget = $state<number | null>(null);
  let reorderPointerID: number | null = null;

  function cancelLongPress() { clearTimeout(pressTimer); pressTimer = undefined; }
  function beginLongPress(event: PointerEvent, track: Track) {
    if (event.pointerType !== "touch" || !window.matchMedia("(max-width: 980px)").matches || (event.target as Element)?.closest("button") || playlistEditing) return;
    pressOrigin = { x: event.clientX, y: event.clientY };
    cancelLongPress();
    pressTimer = setTimeout(() => { actionTrack = track; suppressClickUntil = performance.now() + 700; }, 450);
  }
  function moveLongPress(event: PointerEvent) {
    if (Math.hypot(event.clientX - pressOrigin.x, event.clientY - pressOrigin.y) > 10) cancelLongPress();
  }
  function openTrackMenu(event: MouseEvent, track: Track) {
    if (!window.matchMedia("(max-width: 980px)").matches) return;
    event.preventDefault();
    cancelLongPress();
    actionTrack = track;
  }
  function playRow(track: Track, index: number) {
    if (performance.now() < suppressClickUntil || (playlistEditing && window.matchMedia("(max-width: 980px)").matches)) return;
    onPlayRow(track, index);
  }
  function beginReorder(event: PointerEvent, index: number) {
    event.stopPropagation();
    event.preventDefault();
    draggingIndex = index;
    dragTarget = index;
    reorderPointerID = event.pointerId;
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  }
  function moveReorder(event: PointerEvent) {
    if (event.pointerId !== reorderPointerID || draggingIndex === null || !tableEl) return;
    event.preventDefault();
    if (scrollTarget instanceof HTMLElement) {
      const viewport = scrollTarget.getBoundingClientRect();
      if (event.clientY < viewport.top + 44) scrollTarget.scrollTop -= rowHeight / 4;
      if (event.clientY > viewport.bottom - 44) scrollTarget.scrollTop += rowHeight / 4;
    }
    dragTarget = Math.min(visibleTracks.length - 1, Math.max(0, Math.floor((event.clientY - tableEl.getBoundingClientRect().top) / rowHeight)));
  }
  function finishReorder(event: PointerEvent) {
    if (event.pointerId !== reorderPointerID) return;
    event.stopPropagation();
    if (draggingIndex !== null && dragTarget !== null && draggingIndex !== dragTarget) onMovePlaylistTrack?.(draggingIndex, dragTarget);
    cancelReorder();
    suppressClickUntil = performance.now() + 300;
  }
  function cancelReorder() {
    draggingIndex = null;
    dragTarget = null;
    reorderPointerID = null;
  }
  function keyboardReorder(event: KeyboardEvent, track: Track, index: number) {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    event.stopPropagation();
    const target = Math.max(0, Math.min(visibleTracks.length - 1, index + (event.key === "ArrowUp" ? -1 : 1)));
    if (target === index) return;
    onMovePlaylistTrack?.(index, target);
    void tick().then(() => {
      const handles = surfaceEl?.querySelectorAll<HTMLButtonElement>(".native-playlist-reorder");
      Array.from(handles ?? []).find(handle => handle.dataset.trackId === track.id)?.focus();
    });
  }

  let surfaceEl: HTMLElement | null = $state(null);
  let actionTrack: Track | null = $state(null);
  let tableEl: HTMLDivElement | null = $state(null);
  let scrollTarget: HTMLElement | Window | null = null;
  let resizeObserver: ResizeObserver | null = null;
  let mounted = $state(false);
  let virtualFrame = 0;
  let rowHeight = $state(58);
  let virtualStart = $state(0);
  let virtualEnd = $state(INITIAL_RENDER_ROWS);
  let virtualHeight = $derived(visibleTracks.length * rowHeight);
  let clampedVirtualStart = $derived(Math.min(virtualStart, Math.max(visibleTracks.length - 1, 0)));
  let clampedVirtualEnd = $derived(Math.min(virtualEnd, visibleTracks.length));
  let virtualRows: Array<{ track: Track; index: number }> = $derived(
    visibleTracks
      .slice(clampedVirtualStart, clampedVirtualEnd)
      .map((track, offset) => ({ track, index: clampedVirtualStart + offset }))
  );
  let virtualPadTop = $derived(clampedVirtualStart * rowHeight);

  $effect(() => {
    if (visibleTracks.length > 0 && virtualStart >= visibleTracks.length) {
      virtualStart = 0;
      virtualEnd = Math.min(INITIAL_RENDER_ROWS, visibleTracks.length);
    }
  });

  $effect(() => {
    visibleTracks;
    rowHeight;
    if (mounted) {
      void tick().then(scheduleVirtualUpdate);
    }
  });

  onMount(() => {
    mounted = true;
    // The surface exists even when the list is empty. Binding through the
    // conditional table would subscribe to window until the next mount.
    scrollTarget = nearestScrollParent(surfaceEl);
    resizeObserver = new ResizeObserver(() => {
      updateRowHeight();
      scheduleVirtualUpdate();
    });

    if (surfaceEl) {
      resizeObserver.observe(surfaceEl);
    }

    if (scrollTarget instanceof HTMLElement) {
      resizeObserver.observe(scrollTarget);
      scrollTarget.addEventListener("scroll", scheduleVirtualUpdate, { passive: true });
    } else {
      window.addEventListener("scroll", scheduleVirtualUpdate, { passive: true });
      window.addEventListener("resize", scheduleVirtualUpdate);
    }

    updateRowHeight();
    updateVirtualWindow();
    // Keep receiving the drag when virtualization unmounts its original row.
    window.addEventListener("pointermove", moveReorder, { passive: false });
    window.addEventListener("pointerup", finishReorder);
    window.addEventListener("pointercancel", cancelReorder);

    return () => {
      mounted = false;
      cancelLongPress();
      cancelReorder();
      window.removeEventListener("pointermove", moveReorder);
      window.removeEventListener("pointerup", finishReorder);
      window.removeEventListener("pointercancel", cancelReorder);
      if (virtualFrame) {
        cancelAnimationFrame(virtualFrame);
        virtualFrame = 0;
      }
      if (scrollTarget instanceof HTMLElement) {
        scrollTarget.removeEventListener("scroll", scheduleVirtualUpdate);
      } else {
        window.removeEventListener("scroll", scheduleVirtualUpdate);
        window.removeEventListener("resize", scheduleVirtualUpdate);
      }
      resizeObserver?.disconnect();
      resizeObserver = null;
      scrollTarget = null;
    };
  });

  function handleRowKeydown(event: KeyboardEvent, track: Track, index: number) {
    if (event.target !== event.currentTarget) return;
    if ((event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) && window.matchMedia("(max-width: 980px)").matches) {
      event.preventDefault();
      actionTrack = track;
      return;
    }
    if (event.key !== "Enter" && event.key !== " ") {
      return;
    }

    event.preventDefault();
    playRow(track, index);
  }

  function scheduleVirtualUpdate() {
    if (!mounted || typeof requestAnimationFrame === "undefined") {
      updateVirtualWindow();
      return;
    }

    if (virtualFrame) {
      return;
    }

    virtualFrame = requestAnimationFrame(() => {
      virtualFrame = 0;
      updateVirtualWindow();
    });
  }

  function updateRowHeight() {
    if (!tableEl) {
      return;
    }

    const value = Number.parseFloat(getComputedStyle(tableEl).getPropertyValue("--track-row-height"));
    if (Number.isFinite(value) && value > 0 && value !== rowHeight) {
      rowHeight = value;
    }
  }

  function updateVirtualWindow() {
    updateRowHeight();

    if (!tableEl || visibleTracks.length === 0) {
      virtualStart = 0;
      virtualEnd = 0;
      return;
    }

    const tableRect = tableEl.getBoundingClientRect();
    let viewportTop = 0;
    let viewportBottom = window.innerHeight;
    if (scrollTarget instanceof HTMLElement) {
      const scrollRect = scrollTarget.getBoundingClientRect();
      viewportTop = scrollRect.top;
      viewportBottom = scrollRect.bottom;
    }

    const nextStart = Math.max(0, Math.floor((viewportTop - tableRect.top) / rowHeight) - OVERSCAN_ROWS);
    const visibleEnd = Math.ceil((viewportBottom - tableRect.top) / rowHeight) + OVERSCAN_ROWS;
    const nextEnd = Math.min(visibleTracks.length, Math.max(nextStart + 1, visibleEnd));

    virtualStart = nextStart;
    virtualEnd = nextEnd;
  }

  function nearestScrollParent(element: HTMLElement | null): HTMLElement | Window {
    let parent = element?.parentElement ?? null;
    while (parent) {
      const overflowY = getComputedStyle(parent).overflowY;
      if (overflowY === "auto" || overflowY === "scroll" || overflowY === "overlay") {
        return parent;
      }
      parent = parent.parentElement;
    }
    return window;
  }
</script>

<section class="track-surface" class:search-results={viewTitle === "Search"} aria-label="Tracks" bind:this={surfaceEl}>
  <div class="list-toolbar" aria-label={`${viewTitle} actions`}>
    <div class="list-meta">
      <span>{listMeta}</span>
    </div>
    {#if !isQueueView}
      <div class="sort-chips" role="group" aria-label="Sort">
        <button class:active={sortKey === "title"} type="button" onclick={() => onSetSort("title")}>Title</button>
        <button class:active={sortKey === "album"} type="button" onclick={() => onSetSort("album")}>Album</button>
        <button class:active={sortKey === "duration"} type="button" onclick={() => onSetSort("duration")}>Time</button>
      </div>
    {/if}
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
        {#if onDownloadAll && visibleTracks.length > 0}
          <button class="ui-button native-download-all" type="button" disabled={collectionDownloaded || collectionDownloading}
            aria-label={collectionDownloaded ? "All songs downloaded" : collectionDownloading ? "Downloading songs" : "Download all songs"}
            onclick={onDownloadAll}>
            {#if collectionDownloaded}<Check size={19} />{:else if collectionDownloading}<LoaderCircle class="spin-icon" size={19} />{:else}<ArrowDownToLine size={19} />{/if}
          </button>
        {/if}
      {/if}
    </div>
  </div>
  {#if visibleTracks.length > 0}
    <div class="track-table" bind:this={tableEl}>
      <div class="track-window" style={`height: ${virtualHeight}px;`}>
        <div class="track-window-slice" style={`transform: translateY(${virtualPadTop}px);`}>
      {#each virtualRows as { track, index } (`${track.id}:${index}`)}
        <div
          class="track-row"
          class:active={currentTrackId === track.id}
          class:lastVisibleRow={index === visibleTracks.length - 1}
          class:playlist-editing={playlistEditing && !guestMode}
          class:playlist-dragging={draggingIndex === index}
          class:playlist-drop-target={dragTarget === index && draggingIndex !== index}
          role="button"
          tabindex="0"
          aria-label={currentTrackId === track.id && isPlaying ? `Pause ${track.title}` : `Play ${track.title}`}
          onclick={() => playRow(track, index)}
          oncontextmenu={(event) => openTrackMenu(event, track)}
          onpointerdown={(event) => beginLongPress(event, track)}
          onpointermove={moveLongPress}
          onpointerup={cancelLongPress}
          onpointercancel={cancelLongPress}
          onkeydown={(event) => handleRowKeydown(event, track, index)}
        >
          {#if playlistEditing && !guestMode && onRemovePlaylistTrack}
            <button class="native-playlist-remove" type="button" aria-label={`Remove ${track.title} from playlist`} onclick={(event) => { event.stopPropagation(); onRemovePlaylistTrack?.(index); }}><CircleMinus size={22} /></button>
          {/if}
          <div class="track-title-cell">
            {#if track.artwork_url}
              <ArtworkImage class="artwork" src={track.artwork_url} alt="" loading="lazy" decoding="async" />
            {:else}
              <span class="artwork placeholder"><Music2 size={18} /></span>
            {/if}
            <div>
              <strong>{track.title}</strong>
              <span class="track-artist">{#if downloadedIDs.has(track.id)}<CircleArrowDown class="native-download-marker" size={11} aria-label="Downloaded" />{/if}{track.artist}</span>
            </div>
          </div>

          <button
            class="like-button"
            class:hidden-for-guests={guestMode}
            class:liked={track.is_liked}
            title={track.is_liked ? `Remove ${track.title} from Liked Songs` : `Add ${track.title} to Liked Songs`}
            aria-label={track.is_liked ? `Remove ${track.title} from Liked Songs` : `Add ${track.title} to Liked Songs`}
            aria-pressed={track.is_liked}
            type="button"
            onclick={(event) => {
              event.stopPropagation();
              onToggleLike(track);
            }}
          >
            <Heart size={16} fill={track.is_liked ? "currentColor" : "none"} />
          </button>
          {#if currentTrackId === track.id}
            <span class="table-duration track-eq" class:paused={!isPlaying} aria-hidden="true"><i></i><i></i><i></i></span>
            <span class="native-track-state" aria-label={isPlaying ? "Playing" : "Paused"}>{#if isPlaying}<AudioLines size={14} />{:else}<Pause size={13} fill="currentColor" />{/if}</span>
          {:else}
            <span class="table-duration">{formatDuration(track.duration_seconds)}</span>
          {/if}
          {#if !isQueueView}
            <button
              class="row-action"
              title={`Add ${track.title} to queue`}
              aria-label={`Add ${track.title} to queue`}
              type="button"
              onclick={(event) => {
                event.stopPropagation();
                onQueueTrack(track);
              }}
            >
              <ListEnd size={16} />
            </button>
          {/if}
          {#if !isQueueView}
            <button class="mobile-track-more" type="button" aria-label={`More actions for ${track.title}`} onclick={(event) => { event.stopPropagation(); actionTrack = track; }}><Ellipsis size={21} /></button>
          {/if}
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
              class:hidden-for-guests={guestMode}
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
          {#if playlistEditing && !guestMode && onMovePlaylistTrack}
            <button class="native-playlist-reorder" data-track-id={track.id} type="button" aria-label={`Reorder ${track.title}`} title="Drag to reorder, or use the up and down arrow keys."
              onpointerdown={(event) => beginReorder(event, index)}
              onclick={(event) => event.stopPropagation()}
              onkeydown={(event) => keyboardReorder(event, track, index)}><GripHorizontal size={22} /></button>
          {/if}
        </div>
      {/each}
        </div>
      </div>
    </div>
  {:else}
    <div class="empty-state">
      <Music2 size={32} />
      <p class="desktop-empty-label">No tracks here.</p>
      <strong class="native-empty-label">{emptyTitle}</strong>
      {#if emptyDescription}<p class="native-empty-label">{emptyDescription}</p>{/if}
    </div>
  {/if}
</section>

{#if actionTrack}
  {@const track = actionTrack}
  <MobileSheet title={track.title} onClose={() => { actionTrack = null; }}>
    <div class="mobile-track-actions">
      {#if !guestMode}
        <button type="button" onclick={() => { onToggleLike(track); actionTrack = null; }}><Heart size={21} fill={track.is_liked ? "currentColor" : "none"} />{track.is_liked ? "Unlike" : "Like"}</button>
      {/if}
      {#if onQueueNext}<button type="button" onclick={() => { onQueueNext?.(track); actionTrack = null; }}><ListStart size={21} /> Play Next</button>{/if}
      <button type="button" onclick={() => { onQueueTrack(track); actionTrack = null; }}><ListEnd size={21} /> Play Last</button>
      {#if !guestMode}
        <button type="button" onclick={() => { onEditPlaylists(track); actionTrack = null; }}><ListPlus size={21} /> Add to Playlist</button>
      {/if}
      {#if downloadedIDs.has(track.id) && onRemoveDownload}
        <button type="button" onclick={() => { onRemoveDownload?.(track); actionTrack = null; }}><Trash2 size={21} /> Remove Download</button>
      {:else if onDownloadTrack}
        <button type="button" disabled={downloadingIDs.has(track.id)} onclick={() => { onDownloadTrack?.(track); actionTrack = null; }}>
          {#if downloadingIDs.has(track.id)}<LoaderCircle class="spin-icon" size={21} /> Downloading{:else}<CircleArrowDown size={21} /> Download{/if}
        </button>
      {/if}
    </div>
  </MobileSheet>
{/if}
