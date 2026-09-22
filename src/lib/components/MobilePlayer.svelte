<script lang="ts">
  import ArtworkImage from "./ArtworkImage.svelte";
  import { AudioLines, CircleArrowDown, CircleMinus, GripHorizontal, Heart, List, LoaderCircle, Music2, PlusCircle, Repeat, Repeat1, Shuffle, Smartphone, Speaker } from "lucide-svelte";
  import MobileSymbol from "./MobileSymbol.svelte";
  import { tick } from "svelte";
  import ArtworkAtmosphere from "./ArtworkAtmosphere.svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import VirtualRows from "./VirtualRows.svelte";
  import { formatDuration } from "$lib/library";
  import type { PlaybackDevice } from "$lib/sync";
  import type { RepeatMode, Track } from "$lib/types";

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
  let swipeStart = { x: 0, y: 0 };
  let swipedRow = $state("");
  let dragRow = $state<{ group: string; index: number; target: number; pointerId: number } | null>(null);
  let queueAnnouncement = $state("");
  const duration = $derived(Math.max(audioDuration || currentTrack.duration_seconds || 1, 1));
  const progress = $derived(Math.min(100, Math.max(0, currentTime / duration * 100)));
  const shownTime = $derived(scrubTime ?? currentTime);
  const manualQueue = $derived(queue.slice(1, queuedTracksCount + 1));
  const upcomingQueue = $derived(queue.slice(queuedTracksCount + 1));

  function close() { open = false; showQueue = false; editingQueue = false; swipedRow = ""; }
  function closeQueue() { showQueue = false; editingQueue = false; swipedRow = ""; }
  function move(group: string, index: number, target: number) {
    if (index === target) return;
    const restoreFocus = document.activeElement?.classList.contains("queue-reorder-control");
    if (group === "manual") onMoveQueued(index + 1, target + 1);
    else onMoveUpcoming?.(index, target);
    queueAnnouncement = `Moved to position ${target + 1}`;
    if (restoreFocus) void tick().then(() => {
      document.querySelector<HTMLButtonElement>(`[data-queue-group="${group}"][data-queue-index="${target}"] .queue-reorder-control`)?.focus();
    });
  }
  function dragMove(event: PointerEvent) {
    if (!dragRow || event.pointerId !== dragRow.pointerId) return;
    const row = document.elementFromPoint(event.clientX, event.clientY)?.closest<HTMLElement>("[data-queue-index]");
    if (row?.dataset.queueGroup === dragRow.group) dragRow = { ...dragRow, target: Number(row.dataset.queueIndex) };
  }
  function finishMove(event: PointerEvent) {
    if (!dragRow || event.pointerId !== dragRow.pointerId) return;
    if (dragRow) move(dragRow.group, dragRow.index, dragRow.target);
    dragRow = null;
  }
</script>

<svelte:window onpointermove={dragMove} onpointerup={finishMove} onpointercancel={() => { dragRow = null; }} />

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
  <div class="mobile-queue-group">
    <VirtualRows items={tracks} rowHeight={86}>
      {#snippet children(track, index)}
        {@const key = `${group}:${index}`}
        {@const canRemove = group === "manual" || Boolean(onRemoveUpcoming)}
        {@const canMove = group === "manual" || Boolean(onMoveUpcoming)}
        <div class="mobile-queue-row" class:queue-drop-target={dragRow?.group === group && dragRow.target === index && dragRow.index !== index}
          data-queue-group={group} data-queue-index={index}>
          {#if editingQueue && canRemove}
            <button class="mobile-icon-button queue-remove-control" type="button" aria-label={`Remove ${track.title} from queue`}
              onclick={() => { group === "manual" ? onRemoveQueued(index + 1) : onRemoveUpcoming?.(index); }}><CircleMinus size={21} /></button>
          {/if}
          <button class="mobile-queue-play" type="button" aria-label={`Play ${track.title}`}
            onpointerdown={(event) => { swipeStart = { x: event.clientX, y: event.clientY }; }}
            onpointerup={(event) => { const dx = event.clientX - swipeStart.x; if (canRemove && dx < -40 && Math.abs(dx) > Math.abs(event.clientY - swipeStart.y)) swipedRow = key; }}
            onclick={() => { if (swipedRow === key) return; onPlayQueueTrack(group === "manual" ? index + 1 : index + queuedTracksCount + 1); }}>
            {@render artwork(track)}{@render trackCopy(track)}
            {#if !editingQueue}<span class="mobile-queue-duration">{formatDuration(track.duration_seconds)}</span>{/if}
          </button>
          {#if !editingQueue && swipedRow === key && canRemove}
            <button class="queue-swipe-remove" type="button" onclick={() => { group === "manual" ? onRemoveQueued(index + 1) : onRemoveUpcoming?.(index); swipedRow = ""; }}>Remove</button>
          {/if}
          {#if editingQueue && canMove}
            <button class="mobile-icon-button queue-reorder-control" type="button" aria-label={`Reorder ${track.title}. Use up and down arrow keys.`}
              onpointerdown={(event) => { dragRow = { group, index, target: index, pointerId: event.pointerId }; event.currentTarget.setPointerCapture(event.pointerId); }}
              onkeydown={(event) => { if (event.key === "ArrowUp" || event.key === "ArrowDown") { event.preventDefault(); move(group, index, Math.max(0, Math.min(tracks.length - 1, index + (event.key === "ArrowUp" ? -1 : 1)))); } }}><GripHorizontal size={19} /></button>
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
      {#snippet leading()}{#if queuedTracksCount > 0}<button class="mobile-text-button" type="button" onclick={onClearQueue}>Clear</button>{/if}{/snippet}
      {#snippet trailing()}<button class="mobile-text-button" type="button" onclick={() => { editingQueue = !editingQueue; swipedRow = ""; }}>{editingQueue ? "Done" : "Edit"}</button>{/snippet}
      <div class="mobile-queue-content">
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
      <span class="mobile-player-announcement" role="status">{queueAnnouncement}</span>
    </MobileSheet>
  {/if}
{/if}
