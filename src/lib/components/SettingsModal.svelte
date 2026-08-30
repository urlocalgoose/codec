<script lang="ts">
  import {
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
        <button class="settings-row" disabled={importing || importDisabled} type="button" onclick={onImportManifest}>
          {#if importing}
            <LoaderCircle class="spin-icon" size={17} />
          {:else}
            <Upload size={17} />
          {/if}
          <span>Import a manifest</span>
          <small>loud.import.v1</small>
        </button>
        <button class="settings-row" type="button" onclick={onRefresh}>
          <RefreshCw size={17} />
          <span>Refresh library</span>
        </button>
      </div>
    </div>
  </div>
</div>
