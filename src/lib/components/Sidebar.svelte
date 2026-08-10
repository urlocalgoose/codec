<script lang="ts">
  import {
    Check,
    CloudDownload,
    CloudUpload,
    Disc3,
    Home,
    Library,
    ListMusic,
    LoaderCircle,
    Link,
    Palette,
    Radio,
    Server,
    Users
  } from "lucide-svelte";
  import type { Playlist } from "$lib/types";

  let {
    selectedView,
    userPlaylists,
    activeThemeName,
    syncing,
    canUpload,
    syncMessage,
    guestMode = false,
    auxCode = "",
    auxBusy = false,
    syncServerDraft = $bindable(),
    onSelectView,
    onOpenThemeModal,
    onSyncToServer,
    onSyncFromServer,
    onStartAux,
    onEndAux,
    onCopyAuxLink,
    onShowAux
  }: {
    selectedView: string;
    userPlaylists: Playlist[];
    activeThemeName: string;
    syncing: boolean;
    canUpload: boolean;
    syncMessage: string;
    guestMode?: boolean;
    auxCode?: string;
    auxBusy?: boolean;
    syncServerDraft: string;
    onSelectView: (view: string) => void;
    onOpenThemeModal: () => void;
    onSyncToServer: () => void;
    onSyncFromServer: () => void;
    onStartAux: () => void;
    onEndAux: () => void;
    onCopyAuxLink: () => void;
    onShowAux: () => void;
  } = $props();

  const primaryViews = [
    { id: "home", label: "Home", icon: Home },
    { id: "all", label: "All Songs", icon: Library },
    { id: "liked", label: "Liked Songs", icon: Check },
    { id: "artists", label: "Artists", icon: Users },
    { id: "albums", label: "Albums", icon: Disc3 },
    { id: "queue", label: "Queue", icon: ListMusic }
  ];
</script>

<aside class="sidebar" aria-label="Library navigation">
  <nav class="nav-stack" aria-label="Primary">
    {#each primaryViews as view (view.id)}
      <button
        aria-label={view.label}
        class:active={selectedView === view.id}
        title={view.label}
        type="button"
        onclick={() => onSelectView(view.id)}
      >
        <view.icon size={18} />
        <span>{view.label}</span>
      </button>
    {/each}
  </nav>

  <section class="playlist-nav" aria-label="Playlists">
    <div class="section-label">
      <span>Playlists</span>
    </div>
    <div class="playlist-scroll">
      {#each userPlaylists as playlist (playlist.id)}
        <button
          class:active={selectedView === playlist.id}
          type="button"
          onclick={() => onSelectView(playlist.id)}
        >
          <span>{playlist.name}</span>
          <small>{playlist.track_ids.length}</small>
        </button>
      {/each}
    </div>
  </section>

  <section class="theme-nav" aria-label="Themes">
    <div class="section-label">
      <span>Theme</span>
    </div>
    <button class="theme-open-button" type="button" onclick={onOpenThemeModal}>
      <Palette size={18} />
      <span>{activeThemeName}</span>
    </button>
  </section>

  {#if !guestMode}
    <section class="aux-nav" aria-label="Aux">
      <div class="section-label">
        <span>Aux</span>
      </div>
      {#if auxCode}
        <div class="aux-live">
          <button class="aux-code" title="Show the QR" type="button" onclick={onShowAux}>{auxCode}</button>
          <button
            class="ui-button compact"
            title="Copy the join link"
            aria-label="Copy the join link"
            type="button"
            onclick={onCopyAuxLink}
          >
            <Link size={15} />
          </button>
        </div>
        <button class="ui-button compact" disabled={auxBusy} type="button" onclick={onEndAux}>
          End the aux
        </button>
      {:else}
        <button
          class="ui-button compact"
          disabled={auxBusy}
          title="Start a shared listening session"
          type="button"
          onclick={onStartAux}
        >
          <Radio size={15} />
          Start an aux
        </button>
      {/if}
    </section>
  {/if}

  {#if guestMode}
    <section class="aux-nav" aria-label="Aux">
      <div class="section-label">
        <span>Aux</span>
      </div>
      <p class="aux-guest-note">You're on the aux <strong>{auxCode}</strong> — add songs to the queue.</p>
    </section>
  {:else}
  <section class="sync-nav" aria-label="Sync">
    <div class="section-label">
      <span>Sync</span>
    </div>
    <label class="sync-url-field compact">
      <Server size={16} />
      <input bind:value={syncServerDraft} placeholder="Server URL" type="url" />
    </label>
    <div class="sync-actions">
      <button
        class="ui-button compact"
        disabled={syncing || !canUpload}
        title="Upload this library to the sync server"
        aria-label="Upload this library to the sync server"
        type="button"
        onclick={onSyncToServer}
      >
        {#if syncing}
          <LoaderCircle class="spin-icon" size={16} />
        {:else}
          <CloudUpload size={16} />
        {/if}
      </button>
      <button
        class="ui-button compact"
        disabled={syncing}
        title="Pull library from the sync server"
        aria-label="Pull library from the sync server"
        type="button"
        onclick={onSyncFromServer}
      >
        <CloudDownload size={16} />
      </button>
    </div>
    {#if syncMessage}
      <small class="sync-status">{syncMessage}</small>
    {/if}
  </section>
{/if}
</aside>
