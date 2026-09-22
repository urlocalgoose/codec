<script lang="ts">
  import ArtworkImage from "./ArtworkImage.svelte";
  import { onMount, tick } from "svelte";
  import { ArrowDownToLine, AudioLines, Check, CircleArrowDown, CircleMinus, Ellipsis, GripHorizontal, Heart, ListEnd, ListPlus, ListStart, LoaderCircle, Music2, Pause, Play, Shuffle, Trash2, X } from "lucide-svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import MobileSwipeRow from "./MobileSwipeRow.svelte";
  import type { SwipeAction, SwipeSide } from "$lib/row-swipe";
  import { queueEdgeScroll } from "$lib/queue-gestures";
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
    listIdentity = "",
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
    listIdentity?: string;
    onMovePlaylistTrack?: (from: number, to: number) => void;
    onRemovePlaylistTrack?: (index: number) => void;
    emptyTitle?: string;
    emptyDescription?: string;
  } = $props();

  const collectionDownloaded = $derived(visibleTracks.length > 0 && visibleTracks.every((track) => downloadedIDs.has(track.id)));
  const collectionDownloading = $derived(visibleTracks.some((track) => downloadingIDs.has(track.id)));
  let suppressClickUntil = 0;
  let openSwipeIdentity = $state("");
  let openSwipeSide = $state<SwipeSide | null>(null);
  const swipeOrder = $derived(JSON.stringify([listIdentity, visibleTracks.map(track => [track.id, track.fingerprint])]));
  let draggingIndex = $state<number | null>(null);
  let dragTarget = $state<number | null>(null);
  let reorderPointerID: number | null = null;
  let reorderOrder = "";
  let reorderFrame = 0;
  let reorderFrameTime = 0;
  let reorderStartY = 0;
  let reorderY = $state(0);
  let reorderPreview = $state<{ track: Track; left: number; width: number; offsetY: number } | null>(null);
  let reorderActive = $state(false);

  function setSwipe(identity: string, side: SwipeSide | null) {
    if (side) { openSwipeIdentity = identity; openSwipeSide = side; }
    else if (openSwipeIdentity === identity) { openSwipeIdentity = ""; openSwipeSide = null; }
  }
  function closeSwipes() { openSwipeIdentity = ""; openSwipeSide = null; }
  function leadingActions(track: Track): SwipeAction[] {
    if (isQueueView) return [];
    return [
      ...(onQueueNext ? [{ id: "next", label: "Play Next", ariaLabel: `Play Next ${track.title}`, icon: "next" as const, tone: "accent" as const, run: () => onQueueNext?.(track) }] : []),
      { id: "last", label: "Play Last", ariaLabel: `Play Last ${track.title}`, icon: "last", tone: "muted", run: () => onQueueTrack(track) }
    ];
  }
  function trailingActions(track: Track, index: number): SwipeAction[] {
    if (guestMode || isQueueView) return [];
    if (onRemovePlaylistTrack) return [{ id: "remove", label: "Remove", ariaLabel: `Remove ${track.title} from playlist`, icon: "remove", tone: "danger", run: () => onRemovePlaylistTrack?.(index) }];
    return [
      { id: "like", label: track.is_liked ? "Unlike" : "Like", ariaLabel: `${track.is_liked ? "Unlike" : "Like"} ${track.title}`, icon: track.is_liked ? "unlike" : "like", tone: "accent", run: () => onToggleLike(track) },
      ...(downloadedIDs.has(track.id) && onRemoveDownload
        ? [{ id: "download", label: "Remove Download", ariaLabel: `Remove download of ${track.title}`, icon: "remove-download" as const, tone: "danger" as const, run: () => onRemoveDownload?.(track) }]
        : onDownloadTrack ? [{ id: "download", label: downloadingIDs.has(track.id) ? "Downloading" : "Download", ariaLabel: `Download ${track.title}`, icon: "download" as const, tone: "muted" as const, disabled: downloadingIDs.has(track.id), run: () => onDownloadTrack?.(track) }] : [])
    ];
  }
  function showTrackMenu(track: Track) {
    closeSwipes();
    actionTrack = track;
  }
  function openTrackMenu(event: MouseEvent, track: Track) {
    if (!window.matchMedia("(max-width: 980px)").matches) return;
    event.preventDefault();
    showTrackMenu(track);
  }
  function playRow(track: Track, index: number) {
    if (performance.now() < suppressClickUntil || (playlistEditing && window.matchMedia("(max-width: 980px)").matches)) return;
    onPlayRow(track, index);
  }
  function beginReorder(event: PointerEvent, index: number) {
    if (!event.isPrimary || event.button !== 0 || !playlistEditing || guestMode || !onMovePlaylistTrack || !surfaceEl || !visibleTracks[index]) return;
    event.stopPropagation();
    event.preventDefault();
    const row = (event.currentTarget as HTMLElement).closest<HTMLElement>(".track-row");
    if (!row) return;
    const bounds = row.getBoundingClientRect();
    draggingIndex = index;
    dragTarget = index;
    reorderPointerID = event.pointerId;
    reorderOrder = swipeOrder;
    reorderStartY = reorderY = event.clientY;
    reorderPreview = { track: visibleTracks[index], left: bounds.left, width: bounds.width, offsetY: event.clientY - bounds.top };
    reorderActive = false;
    surfaceEl.setPointerCapture(event.pointerId);
  }
  function updatePlaylistDrop() {
    if (!tableEl) return;
    dragTarget = Math.min(visibleTracks.length - 1, Math.max(0, Math.floor((reorderY - tableEl.getBoundingClientRect().top) / rowHeight)));
  }
  function scrollPlaylistDrag(time: number) {
    reorderFrame = 0;
    if (!reorderActive || draggingIndex === null || !playlistEditing || guestMode || reorderOrder !== swipeOrder) { cancelReorder(); return; }
    if (scrollTarget instanceof HTMLElement) {
      const viewport = scrollTarget.getBoundingClientRect();
      // Floating controls cover the lower part of the content viewport.
      const controls = surfaceEl?.closest(".app-shell")?.querySelector(".mobile-bottom-controls")?.getBoundingClientRect();
      const bottom = controls ? Math.min(viewport.bottom, controls.top) : viewport.bottom;
      scrollTarget.scrollTop += queueEdgeScroll(reorderY, viewport.top, bottom, time - reorderFrameTime);
    }
    reorderFrameTime = time;
    updatePlaylistDrop();
    reorderFrame = requestAnimationFrame(scrollPlaylistDrag);
  }
  function moveReorder(event: PointerEvent) {
    if (event.pointerId !== reorderPointerID || draggingIndex === null || !tableEl) return;
    if (reorderOrder !== swipeOrder) { cancelReorder(); return; }
    event.preventDefault();
    reorderY = event.clientY;
    if (!reorderActive && Math.abs(reorderY - reorderStartY) < 6) return;
    reorderActive = true;
    updatePlaylistDrop();
    if (!reorderFrame) { reorderFrameTime = performance.now(); reorderFrame = requestAnimationFrame(scrollPlaylistDrag); }
  }
  function finishReorder(event: PointerEvent) {
    if (event.pointerId !== reorderPointerID) return;
    event.stopPropagation();
    const from = draggingIndex, to = dragTarget;
    const commit = reorderActive && reorderOrder === swipeOrder && playlistEditing && !guestMode;
    cancelReorder();
    if (commit && from !== null && to !== null && from !== to) onMovePlaylistTrack?.(from, to);
    suppressClickUntil = performance.now() + 300;
  }
  function cancelReorder() {
    const pointerId = reorderPointerID;
    draggingIndex = null;
    dragTarget = null;
    reorderPointerID = null;
    reorderPreview = null;
    reorderActive = false;
    cancelAnimationFrame(reorderFrame);
    reorderFrame = 0;
    if (pointerId !== null && surfaceEl?.hasPointerCapture(pointerId)) surfaceEl.releasePointerCapture(pointerId);
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
    swipeOrder;
    playlistEditing;
    guestMode;
    closeSwipes();
    actionTrack = null;
    cancelReorder();
  });

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
    window.addEventListener("blur", cancelReorder);
    window.addEventListener("resize", cancelReorder);
    const lostCapture = (event: PointerEvent) => { if (event.target === surfaceEl && event.pointerId === reorderPointerID) cancelReorder(); };
    const hidden = () => { if (document.visibilityState === "hidden") cancelReorder(); };
    surfaceEl?.addEventListener("lostpointercapture", lostCapture);
    document.addEventListener("visibilitychange", hidden);

    return () => {
      mounted = false;
      cancelReorder();
      window.removeEventListener("pointermove", moveReorder);
      window.removeEventListener("pointerup", finishReorder);
      window.removeEventListener("pointercancel", cancelReorder);
      window.removeEventListener("blur", cancelReorder);
      window.removeEventListener("resize", cancelReorder);
      surfaceEl?.removeEventListener("lostpointercapture", lostCapture);
      document.removeEventListener("visibilitychange", hidden);
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
      showTrackMenu(track);
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
        {@const swipeIdentity = JSON.stringify([listIdentity, track.id, track.fingerprint, index])}
        <MobileSwipeRow identity={swipeIdentity} leading={leadingActions(track)} trailing={trailingActions(track, index)}
          disabled={playlistEditing || isQueueView}
          openSide={openSwipeIdentity === swipeIdentity ? openSwipeSide : null}
          onOpenChange={(side) => setSwipe(swipeIdentity, side)}
          onLongPress={() => showTrackMenu(track)}>
        <div
          class="track-row"
          data-track-id={track.id} data-track-index={index}
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
            <button class="mobile-track-more" type="button" aria-label={`More actions for ${track.title}`} onclick={(event) => { event.stopPropagation(); showTrackMenu(track); }}><Ellipsis size={21} /></button>
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
        </MobileSwipeRow>
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

{#if reorderActive && reorderPreview}
  <div class="playlist-drag-preview" aria-hidden="true" style={`left:${reorderPreview.left}px;top:${reorderY - reorderPreview.offsetY}px;width:${reorderPreview.width}px;height:${rowHeight}px`}>
    {#if reorderPreview.track.artwork_url}<ArtworkImage src={reorderPreview.track.artwork_url} alt="" />{:else}<Music2 size={24} />{/if}
    <span><strong>{reorderPreview.track.title}</strong><small>{reorderPreview.track.artist}</small></span><GripHorizontal size={22} />
  </div>
{/if}

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
        {#if onRemovePlaylistTrack}
          <button class="danger" type="button" onclick={() => { const index = visibleTracks.findIndex(row => row.id === track.id && row.fingerprint === track.fingerprint); if (index >= 0) onRemovePlaylistTrack?.(index); actionTrack = null; }}><CircleMinus size={21} /> Remove from Playlist</button>
        {/if}
      {/if}
      {#if !guestMode && downloadedIDs.has(track.id) && onRemoveDownload}
        <button type="button" onclick={() => { onRemoveDownload?.(track); actionTrack = null; }}><Trash2 size={21} /> Remove Download</button>
      {:else if !guestMode && onDownloadTrack}
        <button type="button" disabled={downloadingIDs.has(track.id)} onclick={() => { onDownloadTrack?.(track); actionTrack = null; }}>
          {#if downloadingIDs.has(track.id)}<LoaderCircle class="spin-icon" size={21} /> Downloading{:else}<CircleArrowDown size={21} /> Download{/if}
        </button>
      {/if}
    </div>
  </MobileSheet>
{/if}
