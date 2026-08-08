<script lang="ts">
  import { LoaderCircle, RefreshCw, Search, Server, Upload, X } from "lucide-svelte";

  let {
    searchQuery = $bindable(),
    importing,
    importDisabled,
    onOpenSyncServerModal,
    onImportManifest,
    onRefresh
  }: {
    searchQuery: string;
    importing: boolean;
    importDisabled: boolean;
    onOpenSyncServerModal: () => void;
    onImportManifest: () => void;
    onRefresh: () => void;
  } = $props();

  let searchInputEl: HTMLInputElement | undefined = $state();

  export function focusSearch() {
    searchInputEl?.focus();
  }
</script>

<header class="topbar">
  <label class="search-box" aria-label="Search library">
    <Search size={18} />
    <input
      bind:this={searchInputEl}
      bind:value={searchQuery}
      placeholder="Search"
      type="search"
    />
    {#if searchQuery}
      <button title="Clear search" aria-label="Clear search" type="button" onclick={() => (searchQuery = "")}>
        <X size={16} />
      </button>
    {/if}
  </label>

  <div class="topbar-actions">
    <button title="Sync server" aria-label="Sync server" type="button" onclick={onOpenSyncServerModal}>
      <Server size={18} />
    </button>
    <button
      disabled={importing || importDisabled}
      title="Import playlist manifest"
      aria-label="Import playlist manifest"
      type="button"
      onclick={onImportManifest}
    >
      {#if importing}
        <LoaderCircle class="spin-icon" size={18} />
      {:else}
        <Upload size={18} />
      {/if}
    </button>
    <button title="Refresh library" aria-label="Refresh library" type="button" onclick={onRefresh}>
      <RefreshCw size={18} />
    </button>
  </div>
</header>
