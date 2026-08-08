<script lang="ts">
  import { AlertCircle, CloudDownload, FolderOpen, KeyRound, LoaderCircle, Music2, Server } from "lucide-svelte";
  import type { ThemeId } from "$lib/themes";

  let {
    theme,
    isNative,
    loading,
    errorMessage,
    syncServerDraft = $bindable(),
    syncTokenDraft = $bindable(),
    onChooseFolder,
    onConnect
  }: {
    theme: ThemeId;
    isNative: boolean;
    loading: boolean;
    errorMessage: string;
    syncServerDraft: string;
    syncTokenDraft: string;
    onChooseFolder: () => void;
    onConnect: () => void;
  } = $props();
</script>

<main class="setup-screen" data-theme={theme}>
  <section class="setup-panel" class:web-setup={!isNative} aria-labelledby="setup-title">
    <div class="brand-row">
      <span class="brand-mark"><Music2 size={32} /></span>
      <span>Codec</span>
    </div>
    {#if isNative}
      <span class="setup-mode">Desktop</span>
      <h1 id="setup-title">Local music, folder-first.</h1>
      <p>
        Pick a music folder, or connect to a Codec sync server to push and pull real MP3 files.
      </p>
    {:else}
      <span class="setup-mode">Mobile / Web</span>
      <h1 id="setup-title">Connect to Codec.</h1>
      <p>
        Use the same Codec app from the server that stores your library, playback, and queue.
      </p>
    {/if}
    {#if isNative}
      <div class="setup-actions">
        <button class="primary-action" type="button" onclick={onChooseFolder}>
          <FolderOpen size={18} />
          Open Music Folder
        </button>
      </div>
    {/if}
    <div class="setup-sync-card">
      <div class="setup-sync-copy">
        <strong>Sync Server</strong>
        <span>{isNative ? "Use this desktop as a client or uploader." : "Paste the URL printed by the server."}</span>
      </div>
      <div class="setup-sync">
        <label class="sync-url-field">
          <Server size={17} />
          <input
            bind:value={syncServerDraft}
            placeholder="http://192.168.1.20:8787"
            type="url"
          />
        </label>
        <label class="sync-url-field">
          <KeyRound size={17} />
          <input
            bind:value={syncTokenDraft}
            placeholder="Auth token (optional)"
            type="password"
            autocomplete="off"
          />
        </label>
        <button class="primary-action" disabled={loading || !syncServerDraft.trim()} type="button" onclick={onConnect}>
          {#if loading}
            <LoaderCircle class="spin-icon" size={18} />
          {:else}
            <CloudDownload size={18} />
          {/if}
          Connect
        </button>
      </div>
    </div>
    {#if errorMessage}
      <p class="setup-error"><AlertCircle size={16} /> {errorMessage}</p>
    {/if}
  </section>
</main>
