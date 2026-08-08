<script lang="ts">
  import {
    Music2,
    Pause,
    Play,
    Repeat,
    Repeat1,
    Shuffle,
    SkipBack,
    SkipForward,
    Volume2
  } from "lucide-svelte";
  import { formatDuration } from "$lib/library";
  import type { PlaybackDevice } from "$lib/sync";
  import type { RepeatMode, Track } from "$lib/types";

  let {
    currentTrack,
    isPlaying,
    shuffle,
    repeatMode,
    currentTime,
    audioDuration,
    volume,
    showDeviceControl,
    playbackDeviceOptions,
    activePlaybackDeviceId,
    activePlaybackDeviceName,
    deviceId,
    onToggleShuffle,
    onPrevious,
    onTogglePlayback,
    onNext,
    onToggleRepeat,
    onSeekInput,
    onVolumeInput,
    onDeviceChange
  }: {
    currentTrack: Track | null;
    isPlaying: boolean;
    shuffle: boolean;
    repeatMode: RepeatMode;
    currentTime: number;
    audioDuration: number;
    volume: number;
    showDeviceControl: boolean;
    playbackDeviceOptions: PlaybackDevice[];
    activePlaybackDeviceId: string;
    activePlaybackDeviceName: string;
    deviceId: string;
    onToggleShuffle: () => void;
    onPrevious: () => void;
    onTogglePlayback: () => void;
    onNext: () => void;
    onToggleRepeat: () => void;
    onSeekInput: (event: Event) => void;
    onVolumeInput: (event: Event) => void;
    onDeviceChange: (event: Event) => void;
  } = $props();
</script>

<footer class="player" aria-label="Player">
  <div class="now-playing">
    {#if currentTrack}
      {#if currentTrack.artwork_url}
        <img class="player-art" src={currentTrack.artwork_url} alt="" />
      {:else}
        <span class="player-art placeholder"><Music2 size={20} /></span>
      {/if}
      <div>
        <strong>{currentTrack.title}</strong>
        <span>{currentTrack.artist}</span>
      </div>
    {:else}
      <span class="player-art placeholder"><Music2 size={20} /></span>
      <div>
        <strong>Nothing playing</strong>
        <span>Select a track</span>
      </div>
    {/if}
  </div>

  <div class="transport">
    <div class="transport-buttons">
      <button class:active={shuffle} title="Shuffle" aria-label="Shuffle" aria-pressed={shuffle} type="button" onclick={onToggleShuffle}>
        <Shuffle size={17} />
      </button>
      <button title="Previous" aria-label="Previous" type="button" onclick={onPrevious}>
        <SkipBack size={20} />
      </button>
      <button class="play-button" class:active={isPlaying} title={isPlaying ? "Pause" : "Play"} aria-label={isPlaying ? "Pause" : "Play"} aria-pressed={isPlaying} type="button" onclick={onTogglePlayback}>
        {#if isPlaying}
          <Pause size={24} />
        {:else}
          <Play size={24} />
        {/if}
      </button>
      <button title="Next" aria-label="Next" type="button" onclick={onNext}>
        <SkipForward size={20} />
      </button>
      <button class:active={repeatMode !== "off"} title="Repeat" aria-label="Repeat" aria-pressed={repeatMode !== "off"} type="button" onclick={onToggleRepeat}>
        {#if repeatMode === "one"}
          <Repeat1 size={17} />
        {:else}
          <Repeat size={17} />
        {/if}
      </button>
    </div>

    <div class="progress-row">
      <span>{formatDuration(currentTime)}</span>
      <input
        aria-label="Seek"
        disabled={!currentTrack}
        max={Math.max(audioDuration || currentTrack?.duration_seconds || 1, 1)}
        min="0"
        step="0.1"
        type="range"
        value={currentTime}
        oninput={onSeekInput}
      />
      <span>{formatDuration(audioDuration || currentTrack?.duration_seconds)}</span>
    </div>
  </div>

  <div class="player-side">
    <label class="volume-control" aria-label="Volume">
      <Volume2 size={18} />
      <input max="1" min="0" step="0.01" type="range" value={volume} oninput={onVolumeInput} />
    </label>

    {#if showDeviceControl}
      <label class="device-control" aria-label={`Playback device. Playing on ${activePlaybackDeviceName}`}>
        <span>Playing on</span>
        <select value={activePlaybackDeviceId} onchange={onDeviceChange}>
          {#each playbackDeviceOptions as device (device.device_id)}
            <option value={device.device_id}>
              {device.device_id === deviceId ? `${device.name} (this)` : device.name}
            </option>
          {/each}
        </select>
      </label>
    {/if}
  </div>
</footer>
