<script lang="ts">
  import {
    Archive,
    CloudDownload,
    CloudUpload,
    LoaderCircle,
    Palette,
    Radio,
    RefreshCw,
    Server,
    Upload,
    X
  } from "lucide-svelte";

  let {
    activeThemeName,
    syncing,
    canUpload,
    syncMessage,
    importing,
    importDisabled,
    auxCode,
    auxBusy,
    onOpenThemeModal,
    onOpenSyncServerModal,
    onSyncToServer,
    onSyncFromServer,
    onImportManifest,
    onImportFiles,
    canShare = false,
    onShareLibrary,
    onRefresh,
    onStartAux,
    onShowAux,
    onEndAux,
    onClose
  }: {
    activeThemeName: string;
    syncing: boolean;
    canUpload: boolean;
    syncMessage: string;
    importing: boolean;
    importDisabled: boolean;
    auxCode: string;
    auxBusy: boolean;
    onOpenThemeModal: () => void;
    onOpenSyncServerModal: () => void;
    onSyncToServer: () => void;
    onSyncFromServer: () => void;
    onImportManifest: () => void;
    onImportFiles: (files: File[]) => void;
    canShare?: boolean;
    onShareLibrary?: () => void;
    onRefresh: () => void;
    onStartAux: () => void;
    onShowAux: () => void;
    onEndAux: () => void;
    onClose: () => void;
  } = $props();

  function handleBackdropClick(event: MouseEvent) {
    if (event.target === event.currentTarget) {
      onClose();
    }
  }

  let importInputEl: HTMLInputElement | undefined = $state();

  function handleImportPicked(event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    const files = input.files ? [...input.files] : [];
    input.value = "";
    if (files.length > 0) {
      onImportFiles(files);
    }
  }
</script>

<div class="modal-backdrop" role="presentation" onclick={handleBackdropClick}>
  <div class="app-modal settings-modal" role="dialog" aria-label="Settings" aria-modal="true">
    <header class="modal-header">
      <div>
        <span>Codec</span>
        <h2>Settings</h2>
      </div>
      <button
        class="title-icon-button"
        title="Close"
        aria-label="Close settings"
        type="button"
        onclick={onClose}
      >
        <X size={18} />
      </button>
    </header>

    <div class="settings-groups">
      <div class="settings-group">
        <span class="settings-label">Aux</span>
        {#if auxCode}
          <button class="settings-row" type="button" onclick={onShowAux}>
            <Radio size={17} />
            <span>Live — <strong class="settings-aux-code">{auxCode}</strong></span>
            <small>Show QR</small>
          </button>
          <button class="settings-row" disabled={auxBusy} type="button" onclick={onEndAux}>
            <X size={17} />
            <span>End the aux</span>
          </button>
        {:else}
          <button class="settings-row" disabled={auxBusy} type="button" onclick={onStartAux}>
            <Radio size={17} />
            <span>Start an aux</span>
            <small>Shared listening</small>
          </button>
        {/if}
      </div>

      <div class="settings-group">
        <span class="settings-label">Look</span>
        <button class="settings-row" type="button" onclick={onOpenThemeModal}>
          <Palette size={17} />
          <span>Theme</span>
          <small>{activeThemeName}</small>
        </button>
      </div>

      <div class="settings-group">
        <span class="settings-label">Server</span>
        <button class="settings-row" type="button" onclick={onOpenSyncServerModal}>
          <Server size={17} />
          <span>Sync server</span>
          <small>URL &amp; token</small>
        </button>
        <button class="settings-row" disabled={syncing || !canUpload} type="button" onclick={onSyncToServer}>
          {#if syncing}
            <LoaderCircle class="spin-icon" size={17} />
          {:else}
            <CloudUpload size={17} />
          {/if}
          <span>Upload library to server</span>
        </button>
        <button class="settings-row" disabled={syncing} type="button" onclick={onSyncFromServer}>
          <CloudDownload size={17} />
          <span>Pull from server</span>
        </button>
        {#if syncMessage}
          <p class="settings-note">{syncMessage}</p>
        {/if}
      </div>

      <div class="settings-group">
        <span class="settings-label">Library</span>
        {#if importDisabled}
          <!-- Remote library: MP3s upload straight to the sync server. -->
          <button class="settings-row" disabled={importing} type="button" onclick={() => importInputEl?.click()}>
            {#if importing}
              <LoaderCircle class="spin-icon" size={17} />
            {:else}
              <Upload size={17} />
            {/if}
            <span>Import music</span>
            <small>MP3s, manifest, or .loud.zip</small>
          </button>
          <input
            bind:this={importInputEl}
            type="file"
            accept=".mp3,audio/mpeg,.json,application/json,.zip,application/zip"
            multiple
            hidden
            onchange={handleImportPicked}
          />
        {:else}
          <button class="settings-row" disabled={importing} type="button" onclick={onImportManifest}>
            {#if importing}
              <LoaderCircle class="spin-icon" size={17} />
            {:else}
              <Upload size={17} />
            {/if}
            <span>Import a manifest</span>
            <small>loud.import.v1</small>
          </button>
        {/if}
        {#if canShare}
          <button class="settings-row" type="button" onclick={onShareLibrary}>
            <Archive size={17} />
            <span>Share library</span>
            <small>zip · loud.import.v1</small>
          </button>
        {/if}
        <button class="settings-row" type="button" onclick={onRefresh}>
          <RefreshCw size={17} />
          <span>Refresh library</span>
        </button>
      </div>
    </div>
  </div>
</div>
