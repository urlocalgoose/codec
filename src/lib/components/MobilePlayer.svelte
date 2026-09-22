<script lang="ts">
  import ArtworkImage from "./ArtworkImage.svelte";
  import { ArrowDown, ArrowUp, AudioLines, CircleArrowDown, CircleMinus, GripHorizontal, Heart, List, LoaderCircle, Music2, PlusCircle, Repeat, Repeat1, Shuffle, Smartphone, Speaker } from "lucide-svelte";
  import MobileSymbol from "./MobileSymbol.svelte";
  import { onDestroy, tick, untrack } from "svelte";
  import ArtworkAtmosphere from "./ArtworkAtmosphere.svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import VirtualRows from "./VirtualRows.svelte";
  import { formatDuration } from "$lib/library";
  import type { PlaybackDevice } from "$lib/sync";
  import type { RepeatMode, Track } from "$lib/types";
  import { beginQueueSwipe, finishQueueSwipe, QUEUE_REVEAL_WIDTH, queueDropIndex, queueEdgeScroll, queueEntryKeys, queueOrderMatches, updateQueueSwipe, type QueueGroup, type QueueSwipe } from "$lib/queue-gestures";

  let { currentTrack, isPlaying, shuffle, repeatMode, currentTime, audioDuration,
    showDeviceControl, playbackDeviceOptions, activePlaybackDeviceId, activePlaybackDeviceName, deviceId,
    queue, queuedTracksCount, guestMode, onToggleShuffle, onPrevious, onTogglePlayback, onNext,
    onToggleRepeat, onSeekInput, onDeviceChange, onToggleLike, onEditPlaylists,
    onPlayQueueTrack, onRemoveQueued, onMoveQueued, onClearQueue, theme = "graphite", obscured = false,
    downloadState = "none", onDownload, onRemoveDownload, airPlayAvailable = false, onAirPlay,
    onRemoveUpcoming, onMoveUpcoming }: {
    currentTrack: Track;
    isPlaying: boolean;
    shuffle: boolean;
    repeatMode: RepeatMode;
    currentTime: number;
    audioDuration: number;
    showDeviceControl: boolean;
    playbackDeviceOptions: PlaybackDevice[];
    activePlaybackDeviceId: string;
    activePlaybackDeviceName: string;
    deviceId: string;
    queue: Track[];
    queuedTracksCount: number;
    guestMode: boolean;
    onToggleShuffle: () => void;
    onPrevious: () => void;
    onTogglePlayback: () => void;
    onNext: () => void;
    onToggleRepeat: () => void;
    onSeekInput: (event: Event) => void;
    onDeviceChange: (event: Event) => void;
    onToggleLike: (track: Track) => void;
    onEditPlaylists: (track: Track) => void;
    onPlayQueueTrack: (index: number) => void;
    onRemoveQueued: (index: number) => void;
    onMoveQueued: (index: number, target: number) => void;
    onClearQueue: () => void;
    theme?: string;
    obscured?: boolean;
    downloadState?: "none" | "downloading" | "downloaded";
    onDownload?: (track: Track) => void;
    onRemoveDownload?: (track: Track) => void;
    airPlayAvailable?: boolean;
    onAirPlay?: () => void;
    onRemoveUpcoming?: (index: number) => void;
    onMoveUpcoming?: (index: number, target: number) => void;
  } = $props();

  let open = $state(false);
  let showQueue = $state(false);
  let editingQueue = $state(false);
  let scrubTime = $state<number | null>(null);
  let swipedRow = $state("");
  let swipe = $state<{ key: string; pointerId: number; gesture: QueueSwipe } | null>(null);
  let dragRow = $state<{
    group: QueueGroup; key: string; order: string[]; index: number; target: number; pointerId: number;
    startY: number; y: number; active: boolean; offsetY: number; left: number; width: number; track: Track; actionsWereOpen: boolean;
  } | null>(null);
  let queueContent = $state<HTMLDivElement>();
  let dragScroller: HTMLElement | null = null;
  let dragFrame = 0;
  let dragLastTime = 0;
  let suppressRowClickUntil = 0;
  let moveActions = $state("");
  let queueAnnouncement = $state("");
  const duration = $derived(Math.max(audioDuration || currentTrack.duration_seconds || 1, 1));
  const progress = $derived(Math.min(100, Math.max(0, currentTime / duration * 100)));
  const shownTime = $derived(scrubTime ?? currentTime);
  const manualQueue = $derived(queue.slice(1, queuedTracksCount + 1));
  const upcomingQueue = $derived(queue.slice(queuedTracksCount + 1));
  const manualKeys = $derived(queueEntryKeys(manualQueue, "manual"));
  const upcomingKeys = $derived(queueEntryKeys(upcomingQueue, "upcoming"));
  const queueOrder = $derived(JSON.stringify([manualKeys, upcomingKeys]));

  function keysFor(group: QueueGroup) { return group === "manual" ? manualKeys : upcomingKeys; }
  function tracksFor(group: QueueGroup) { return group === "manual" ? manualQueue : upcomingQueue; }
  function suppressPointerClick() { suppressRowClickUntil = performance.now() + 450; }
  function releaseCapture(pointerId: number) {
    if (queueContent?.hasPointerCapture(pointerId)) queueContent.releasePointerCapture(pointerId);
  }
  function cancelMove() {
    const pointerId = dragRow?.pointerId;
    if (dragRow?.active) suppressPointerClick();
    dragRow = null;
    if (dragFrame) cancelAnimationFrame(dragFrame);
    dragFrame = 0;
    dragScroller = null;
    if (pointerId !== undefined) releaseCapture(pointerId);
  }
  function cancelGestures() {
    cancelMove();
    if (swipe) { suppressPointerClick(); const id = swipe.pointerId; swipe = null; releaseCapture(id); }
    swipedRow = "";
    moveActions = "";
  }
  // VirtualRows reuses slots by index. Never let a recycled slot inherit an
  // open action or commit a captured index after any queue membership change.
  $effect(() => { queueOrder; untrack(cancelGestures); });
  onDestroy(cancelGestures);

  function close() { cancelGestures(); open = false; showQueue = false; editingQueue = false; }
  function closeQueue() { cancelGestures(); showQueue = false; editingQueue = false; }
  function move(group: QueueGroup, key: string, target: number) {
    const index = keysFor(group).indexOf(key);
    if (index < 0 || target < 0 || target >= keysFor(group).length) return;
    if (index === target) return;
    const restoreFocus = document.activeElement?.classList.contains("queue-reorder-control");
    const title = tracksFor(group)[index].title;
    cancelGestures();
    if (group === "manual") onMoveQueued(index + 1, target + 1);
    else onMoveUpcoming?.(index, target);
    queueAnnouncement = `Moved ${title} to position ${target + 1}`;
    if (restoreFocus) void tick().then(() => {
      queueContent?.querySelector<HTMLButtonElement>(`[data-queue-group="${group}"][data-queue-index="${target}"] .queue-reorder-control`)?.focus();
    });
  }
  function remove(group: QueueGroup, key: string) {
    const index = keysFor(group).indexOf(key);
    if (index < 0) return;
    const title = tracksFor(group)[index].title;
    cancelGestures();
    group === "manual" ? onRemoveQueued(index + 1) : onRemoveUpcoming?.(index);
    queueAnnouncement = `Removed ${title} from queue`;
  }
  function startSwipe(event: PointerEvent, key: string, canRemove: boolean) {
    if (!event.isPrimary || event.button !== 0) { cancelGestures(); return; }
    if (dragRow) return;
    const wasOpen = swipedRow === key;
    if (swipedRow && !wasOpen) swipedRow = "";
    moveActions = "";
    if (!canRemove || editingQueue) return;
    swipe = { key, pointerId: event.pointerId, gesture: beginQueueSwipe(event.clientX, event.clientY, performance.now(), wasOpen) };
  }
  function playQueueRow(event: MouseEvent, group: QueueGroup, key: string) {
    if (event.detail !== 0 && performance.now() < suppressRowClickUntil) { event.preventDefault(); return; }
    if (swipedRow) { swipedRow = ""; return; }
    const index = keysFor(group).indexOf(key);
    if (index >= 0) onPlayQueueTrack(group === "manual" ? index + 1 : index + queuedTracksCount + 1);
  }
  function startMove(event: PointerEvent, group: QueueGroup, key: string) {
    if (!event.isPrimary || event.button !== 0) { cancelGestures(); return; }
    const index = keysFor(group).indexOf(key);
    const row = event.currentTarget instanceof HTMLElement ? event.currentTarget.closest<HTMLElement>("[data-queue-key]") : null;
    const panel = queueContent?.closest<HTMLElement>(".mobile-sheet-panel");
    if (index < 0 || !row || !panel || !queueContent) return;
    const actionsWereOpen = moveActions === key;
    cancelGestures();
    const bounds = row.getBoundingClientRect(), panelBounds = panel.getBoundingClientRect();
    dragScroller = queueContent.closest<HTMLElement>(".mobile-sheet-body");
    dragRow = { group, key, order: [...keysFor(group)], index, target: index, pointerId: event.pointerId,
      startY: event.clientY, y: event.clientY, active: false, offsetY: event.clientY - bounds.top,
      left: bounds.left - panelBounds.left, width: bounds.width, track: tracksFor(group)[index], actionsWereOpen };
    // Capture on the persistent list, not a virtual row that can unmount while
    // edge scrolling. A tap is still handled separately from a real drag.
    queueContent.setPointerCapture(event.pointerId);
  }
  function updateDropTarget() {
    if (!dragRow || !queueContent) return;
    const group = queueContent.querySelector<HTMLElement>(`[data-queue-list="${dragRow.group}"]`);
    if (!group) { cancelMove(); return; }
    const target = queueDropIndex(dragRow.y, group.getBoundingClientRect().top, keysFor(dragRow.group).length);
    if (target !== dragRow.target) dragRow = { ...dragRow, target };
  }
  function scrollDragFrame(time: number) {
    dragFrame = 0;
    if (!dragRow?.active || !dragScroller) return;
    if (!showQueue || !editingQueue || !queueOrderMatches(dragRow.order, keysFor(dragRow.group))) { cancelMove(); return; }
    const bounds = dragScroller.getBoundingClientRect();
    const delta = queueEdgeScroll(dragRow.y, bounds.top, bounds.bottom, time - dragLastTime);
    dragLastTime = time;
    if (delta) dragScroller.scrollTop += delta;
    updateDropTarget();
    dragFrame = requestAnimationFrame(scrollDragFrame);
  }
  function pointerMove(event: PointerEvent) {
    if (swipe?.pointerId === event.pointerId) {
      const gesture = updateQueueSwipe(swipe.gesture, event.clientX, event.clientY, performance.now());
      if (gesture.axis === "horizontal") {
        event.preventDefault();
        suppressPointerClick();
        if (!queueContent?.hasPointerCapture(event.pointerId)) queueContent?.setPointerCapture(event.pointerId);
      }
      swipe = { ...swipe, gesture };
    }
    if (!dragRow || event.pointerId !== dragRow.pointerId) return;
    const active = dragRow.active || Math.abs(event.clientY - dragRow.startY) > 6;
    dragRow = { ...dragRow, y: event.clientY, active };
    if (!active) return;
    event.preventDefault();
    suppressPointerClick();
    updateDropTarget();
    if (!dragFrame) { dragLastTime = performance.now(); dragFrame = requestAnimationFrame(scrollDragFrame); }
  }
  function pointerEnd(event: PointerEvent, cancelled = false) {
    if (swipe?.pointerId === event.pointerId) {
      const finished = swipe;
      swipe = null;
      if (finished.gesture.axis !== "pending" || cancelled) suppressPointerClick();
      swipedRow = finishQueueSwipe(finished.gesture, performance.now(), cancelled) ? finished.key : "";
      releaseCapture(event.pointerId);
    }
    if (dragRow?.pointerId !== event.pointerId) return;
    const finished = dragRow;
    cancelMove();
    if (cancelled || !showQueue || !editingQueue || !queueOrderMatches(finished.order, keysFor(finished.group))) return;
    if (finished.active) move(finished.group, finished.key, finished.target);
    else moveActions = finished.actionsWereOpen ? "" : finished.key;
  }
  function previewTop() {
    const panelTop = queueContent?.closest<HTMLElement>(".mobile-sheet-panel")?.getBoundingClientRect().top ?? 0;
    return dragRow ? dragRow.y - dragRow.offsetY - panelTop : 0;
  }
</script>

<svelte:window onpointermove={pointerMove} onpointerup={(event) => pointerEnd(event)} onpointercancel={(event) => pointerEnd(event, true)} onblur={cancelGestures} />

{#snippet artwork(track: Track, large = false)}
  {#if track.artwork_url}
    <ArtworkImage class={large ? "mobile-player-art large-art" : "mobile-player-art"} src={track.artwork_url} alt="" draggable="false" />
  {:else}
    <span class:large-art={large} class="mobile-player-art placeholder"><Music2 size={large ? 76 : 20} /></span>
  {/if}
{/snippet}

{#snippet trackCopy(track: Track)}
  <span class="mobile-track-copy"><strong title={track.title}>{track.title}</strong><span title={track.artist}>{track.artist}</span></span>
{/snippet}

{#snippet skipSymbol(backward = false, size = 31)}
  <svg width={size * 1.26} height={size} viewBox="0 0 32 24" aria-hidden="true" fill="currentColor">
    <g transform={backward ? "translate(32 0) scale(-1 1)" : undefined}><path d="M2 3 16 12 2 21Z M16 3 30 12 16 21Z" /></g>
  </svg>
{/snippet}

{#snippet queueRows(tracks: Track[], group: "manual" | "upcoming")}
  <div class="mobile-queue-group" data-queue-list={group}>
    <VirtualRows items={tracks} rowHeight={86}>
      {#snippet children(track, index)}
        {@const key = keysFor(group)[index]}
        {@const canRemove = group === "manual" || Boolean(onRemoveUpcoming)}
        {@const canMove = group === "manual" || Boolean(onMoveUpcoming)}
        {@const offset = swipe?.key === key ? swipe.gesture.offset : swipedRow === key ? -QUEUE_REVEAL_WIDTH : 0}
        <div class="mobile-queue-row" class:queue-drop-target={dragRow?.active && dragRow.group === group && dragRow.target === index && dragRow.index !== index}
          class:queue-swiping={swipe?.key === key && swipe.gesture.axis === "horizontal"} class:queue-swipe-open={swipedRow === key}
          class:queue-drag-source={dragRow?.active && dragRow.key === key}
          data-queue-group={group} data-queue-index={index} data-queue-key={key} style={`--queue-swipe-x:${offset}px`}>
          {#if !editingQueue && canRemove}
            <button class="queue-swipe-remove" type="button" tabindex={swipedRow === key ? 0 : -1} inert={swipedRow !== key}
              aria-label={`Remove ${track.title} from queue`} onclick={() => remove(group, key)}>Remove</button>
          {/if}
          <div class="mobile-queue-row-content">
          {#if editingQueue && canRemove}
            <button class="mobile-icon-button queue-remove-control" type="button" aria-label={`Remove ${track.title} from queue`}
              onclick={() => remove(group, key)}><CircleMinus size={21} /></button>
          {/if}
          <button class="mobile-queue-play" type="button" aria-label={`Play ${track.title}`}
            onpointerdown={(event) => startSwipe(event, key, canRemove)}
            onclick={(event) => playQueueRow(event, group, key)}>
            {@render artwork(track)}{@render trackCopy(track)}
            {#if !editingQueue}<span class="mobile-queue-duration">{formatDuration(track.duration_seconds)}</span>{/if}
          </button>
          {#if editingQueue && canMove}
            <button class="mobile-icon-button queue-reorder-control" type="button" aria-label={`Reorder ${track.title}. Use up and down arrow keys.`} aria-expanded={moveActions === key}
              onpointerdown={(event) => startMove(event, group, key)}
              onclick={(event) => { if (event.detail === 0) moveActions = moveActions === key ? "" : key; }}
              onkeydown={(event) => { if (event.key === "ArrowUp" || event.key === "ArrowDown") { event.preventDefault(); move(group, key, Math.max(0, Math.min(tracks.length - 1, index + (event.key === "ArrowUp" ? -1 : 1)))); } }}><GripHorizontal size={19} /></button>
          {/if}
          </div>
          {#if editingQueue && moveActions === key && canMove}
            <div class="queue-move-actions" role="group" aria-label={`Move ${track.title}`}>
              <button class="mobile-icon-button" type="button" aria-label={`Move ${track.title} up`} disabled={index === 0} onclick={() => move(group, key, index - 1)}><ArrowUp size={20} /></button>
              <button class="mobile-icon-button" type="button" aria-label={`Move ${track.title} down`} disabled={index === tracks.length - 1} onclick={() => move(group, key, index + 1)}><ArrowDown size={20} /></button>
            </div>
          {/if}
        </div>
      {/snippet}
    </VirtualRows>
  </div>
{/snippet}

<div class="mobile-mini-player" aria-label="Mini player">
  <button class="mobile-mini-summary" type="button" aria-label={`Open Now Playing: ${currentTrack.title}`} onclick={() => { open = true; }}>
    {@render artwork(currentTrack)}{@render trackCopy(currentTrack)}
  </button>
  <button class="mobile-icon-button" type="button" aria-label={isPlaying ? "Pause" : "Play"} onclick={onTogglePlayback}>
    {#key isPlaying}<MobileSymbol name={isPlaying ? "pause" : "play"} size={20}/>{/key}
  </button>
  <button class="mobile-icon-button" type="button" aria-label="Next" onclick={onNext}>{@render skipSymbol(false, 21)}</button>
  <span class="mobile-mini-progress" style={`width:${progress}%`} aria-hidden="true"></span>
</div>

{#if open}
  <MobileSheet title="Now Playing" onClose={close} wide presentation="player">
    {#snippet background()}<ArtworkAtmosphere artwork={currentTrack.artwork_url} {theme} visible={!showQueue && !obscured} />{/snippet}
    <div class="mobile-now-playing">
      <div class="mobile-now-spacer before-art" aria-hidden="true"></div>
      <div class="mobile-now-art" class:paused={!isPlaying}>{@render artwork(currentTrack, true)}</div>
      <div class="mobile-now-spacer after-art" aria-hidden="true"></div>
      <div class="mobile-now-title">
        {@render trackCopy(currentTrack)}
        {#if !guestMode}
          <button class="mobile-icon-button" type="button" aria-label="Add to playlist" onclick={() => onEditPlaylists(currentTrack)}><PlusCircle size={21} /></button>
          <button class="mobile-icon-button" class:active={currentTrack.is_liked} type="button" aria-label={currentTrack.is_liked ? "Remove from Liked Songs" : "Add to Liked Songs"} aria-pressed={currentTrack.is_liked} onclick={() => onToggleLike(currentTrack)}><Heart size={21} fill={currentTrack.is_liked ? "currentColor" : "none"} /></button>
        {/if}
      </div>
      <div class="mobile-now-progress">
        <input aria-label="Seek" type="range" min="0" max={duration} step="0.1" value={shownTime} style={`--fill:${shownTime / duration * 100}%`}
          oninput={(event) => { scrubTime = Number(event.currentTarget.value); }}
          onchange={(event) => { onSeekInput(event); scrubTime = null; }} />
        <div><span>{formatDuration(shownTime)}</span><span>{formatDuration(audioDuration || currentTrack.duration_seconds)}</span></div>
      </div>
      <div class="mobile-now-transport">
        <button class="mobile-icon-button" class:active={shuffle} aria-label="Shuffle" aria-pressed={shuffle} type="button" onclick={onToggleShuffle}><Shuffle size={20} /></button>
        <button class="mobile-icon-button" aria-label="Previous" type="button" onclick={onPrevious}>{@render skipSymbol(true)}</button>
        <button class="mobile-icon-button mobile-now-play" aria-label={isPlaying ? "Pause" : "Play"} type="button" onclick={onTogglePlayback}>
          {#key isPlaying}<MobileSymbol name={isPlaying ? "pause" : "play"} size={42}/>{/key}
        </button>
        <button class="mobile-icon-button" aria-label="Next" type="button" onclick={onNext}>{@render skipSymbol()}</button>
        <button class="mobile-icon-button" class:active={repeatMode !== "off"} aria-label={repeatMode === "one" ? "Repeat one" : "Repeat"} aria-pressed={repeatMode !== "off"} type="button" onclick={onToggleRepeat}>
          {#if repeatMode === "one"}<Repeat1 size={20} />{:else}<Repeat size={20} />{/if}
        </button>
      </div>
      <div class="mobile-now-spacer before-footer" aria-hidden="true"></div>
      <div class="mobile-now-footer">
        {#if showDeviceControl}
          <label class="mobile-now-device" class:remote={activePlaybackDeviceId !== deviceId}>
            {#if activePlaybackDeviceId === deviceId}<Smartphone size={14} />{:else}<Speaker size={14} />{/if}
            <span aria-hidden="true">{activePlaybackDeviceName}</span>
            <select aria-label={`Playback device. Playing on ${activePlaybackDeviceName}`} value={activePlaybackDeviceId} onchange={onDeviceChange}>
              {#each playbackDeviceOptions as device (device.device_id)}<option value={device.device_id}>{device.name}{device.device_id === deviceId ? " (this device)" : ""}</option>{/each}
            </select>
          </label>
        {/if}
        <div class="mobile-now-footer-actions">
          {#if airPlayAvailable && onAirPlay}<button class="mobile-icon-button" aria-label="AirPlay" type="button" onclick={onAirPlay}><MobileSymbol name="airplay" size={20}/></button>{/if}
          {#if onDownload}
            <button class="mobile-icon-button" class:active={downloadState === "downloaded"} aria-label={downloadState === "downloaded" ? "Remove download" : downloadState === "downloading" ? "Downloading" : "Download track"}
              disabled={downloadState === "downloading" || (downloadState === "downloaded" && !onRemoveDownload)} type="button"
              onclick={() => { downloadState === "downloaded" ? onRemoveDownload?.(currentTrack) : onDownload(currentTrack); }}>
              {#if downloadState === "downloading"}<LoaderCircle class="spin-icon" size={20} />{:else}<CircleArrowDown size={20} fill={downloadState === "downloaded" ? "currentColor" : "none"} />{/if}
            </button>
          {/if}
          <button class="mobile-icon-button" aria-label="Queue" type="button" onclick={() => { showQueue = true; }}><List size={22} /></button>
        </div>
      </div>
    </div>
  </MobileSheet>
  {#if showQueue}
    <MobileSheet title="Queue" onClose={closeQueue} wide presentation="queue">
      {#snippet leading()}{#if queuedTracksCount > 0}<button class="mobile-text-button" type="button" onclick={() => { cancelGestures(); onClearQueue(); }}>Clear</button>{/if}{/snippet}
      {#snippet trailing()}<button class="mobile-text-button" type="button" onclick={() => { cancelGestures(); editingQueue = !editingQueue; }}>{editingQueue ? "Done" : "Edit"}</button>{/snippet}
      <div class="mobile-queue-content" bind:this={queueContent} data-sheet-no-drag
        onlostpointercapture={(event) => { if (event.target === event.currentTarget && (swipe?.pointerId === event.pointerId || dragRow?.pointerId === event.pointerId)) pointerEnd(event, true); }}>
        <section class="mobile-queue-section">
          <h3>Now Playing</h3>
          <div class="mobile-queue-group">
            <div class="mobile-queue-row current">{@render artwork(currentTrack)}{@render trackCopy(currentTrack)}<span class="mobile-queue-playing" aria-label={isPlaying ? "Playing" : "Paused"}>{#if isPlaying}<AudioLines size={17} />{:else}<MobileSymbol name="pause" size={16}/>{/if}</span></div>
          </div>
        </section>
        {#if manualQueue.length}
          <section class="mobile-queue-section"><h3>In Queue</h3>{@render queueRows(manualQueue, "manual")}</section>
        {/if}
        {#if upcomingQueue.length}
          <section class="mobile-queue-section"><h3>Up Next</h3>{@render queueRows(upcomingQueue, "upcoming")}</section>
        {/if}
      </div>
      {#if dragRow?.active}
        <div class="queue-drag-preview" aria-hidden="true" style={`top:${previewTop()}px;left:${dragRow.left}px;width:${dragRow.width}px`}>
          {@render artwork(dragRow.track)}{@render trackCopy(dragRow.track)}<GripHorizontal size={19} />
        </div>
      {/if}
      <span class="mobile-player-announcement" role="status">{queueAnnouncement}</span>
    </MobileSheet>
  {/if}
{/if}
