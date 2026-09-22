<script lang="ts">
  import { ArrowDownUp, Check, Ellipsis, Image, LoaderCircle, Pencil, Plus, Trash2, X } from "lucide-svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import type { Playlist, SortKey } from "$lib/types";

  let {
    viewTitle,
    viewSubtitle,
    selectedPlaylist,
    isEditing,
    renaming,
    canEditCover = false,
    mobileToolbarOnly = false,
    mobileSortKey = "default",
    onMobileSort,
    playlistEditing = false,
    onTogglePlaylistEdit,
    onAddSongs,
    onDeletePlaylist,
    playlistNameDraft = $bindable(),
    onStartRename,
    onCommitRename,
    onCancelRename,
    onChangeCover
  }: {
    viewTitle: string;
    viewSubtitle: string;
    selectedPlaylist: Playlist | null;
    isEditing: boolean;
    renaming: boolean;
    canEditCover?: boolean;
    mobileToolbarOnly?: boolean;
    mobileSortKey?: SortKey;
    onMobileSort?: (sort: SortKey) => void;
    playlistEditing?: boolean;
    onTogglePlaylistEdit?: () => void;
    onAddSongs?: () => void;
    onDeletePlaylist?: () => void;
    playlistNameDraft: string;
    onStartRename: (playlist: Playlist) => void;
    onCommitRename: () => void;
    onCancelRename: () => void;
    onChangeCover?: (file: File) => void;
  } = $props();

  let nameInputEl: HTMLInputElement | undefined = $state();
  let coverInputEl: HTMLInputElement | undefined = $state();
  let optionsOpen = $state(false);

  function handleCoverPicked(event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    input.value = "";
    if (file && onChangeCover) {
      onChangeCover(file);
    }
  }

  $effect(() => {
    if (isEditing && nameInputEl) {
      nameInputEl.focus();
      nameInputEl.select();
    }
  });

  function handleNameKeydown(event: KeyboardEvent) {
    if (event.key === "Enter") {
      event.preventDefault();
      onCommitRename();
    }

    if (event.key === "Escape") {
      event.preventDefault();
      onCancelRename();
    }
  }
</script>

{#if mobileToolbarOnly}
  <div class="native-collection-toolbar" aria-label={`${viewTitle} options`}>
    {#if selectedPlaylist && !selectedPlaylist.is_liked}
      {#if onTogglePlaylistEdit}
        <button class="mobile-text-button" type="button" aria-pressed={playlistEditing} onclick={onTogglePlaylistEdit}>{playlistEditing ? "Done" : "Edit"}</button>
      {/if}
      {#if canEditCover || onDeletePlaylist || onAddSongs}<span class="native-playlist-media">
      {#if canEditCover || onDeletePlaylist}
        <button class="mobile-icon-button" type="button" aria-label="Playlist options" onclick={() => optionsOpen = true}><Ellipsis size={21} /></button>
        <input bind:this={coverInputEl} type="file" accept="image/*" hidden onchange={handleCoverPicked} />
      {/if}
      {#if onAddSongs}
        <button class="mobile-icon-button" type="button" aria-label="Add songs" onclick={onAddSongs}><Plus size={22} /></button>
      {/if}
      </span>{/if}
    {:else if onMobileSort}
      <label class="native-sort-control"><ArrowDownUp size={21} aria-hidden="true" />
        <select aria-label="Sort songs" value={mobileSortKey} onchange={(event) => onMobileSort?.(event.currentTarget.value as SortKey)}>
          <option value="default">Default</option><option value="title">Title</option><option value="artist">Artist</option><option value="added">Newest</option>
          {#if !["default", "title", "artist", "added"].includes(mobileSortKey)}<option value={mobileSortKey}>{mobileSortKey === "album" ? "Album" : "Time"}</option>{/if}
        </select>
      </label>
    {/if}
  </div>
{:else}
<section class="view-header">
  <div class="view-heading">
    {#if selectedPlaylist && isEditing}
      <form
        class="title-edit"
        onsubmit={(event) => {
          event.preventDefault();
          onCommitRename();
        }}
      >
        <input
          bind:this={nameInputEl}
          bind:value={playlistNameDraft}
          class="playlist-title-input"
          disabled={renaming}
          aria-label="Playlist title"
          maxlength="96"
          onkeydown={handleNameKeydown}
        />
        <button
          class="title-icon-button primary"
          disabled={renaming}
          title="Save playlist title"
          aria-label="Save playlist title"
          type="submit"
        >
          {#if renaming}
            <LoaderCircle class="spin-icon" size={17} />
          {:else}
            <Check size={18} />
          {/if}
        </button>
        <button
          class="title-icon-button"
          disabled={renaming}
          title="Cancel rename"
          aria-label="Cancel rename"
          type="button"
          onclick={onCancelRename}
        >
          <X size={18} />
        </button>
      </form>
    {:else}
      <div class="title-row">
        <h1>{viewTitle}</h1>
        {#if selectedPlaylist && !selectedPlaylist.is_liked}
          <button
            class="title-icon-button"
            title="Edit playlist title"
            aria-label="Edit playlist title"
            type="button"
            onclick={() => onStartRename(selectedPlaylist)}
          >
            <Pencil size={17} />
          </button>
        {/if}
        {#if selectedPlaylist && canEditCover}
          <button
            class="title-icon-button"
            title="Change playlist cover"
            aria-label="Change playlist cover"
            type="button"
            onclick={() => coverInputEl?.click()}
          >
            <Image size={17} />
          </button>
          <input
            bind:this={coverInputEl}
            type="file"
            accept="image/*"
            hidden
            onchange={handleCoverPicked}
          />
        {/if}
      </div>
    {/if}
    <p>{viewSubtitle}</p>
  </div>
</section>

{/if}

{#if optionsOpen && mobileToolbarOnly && selectedPlaylist && !selectedPlaylist.is_liked}
  <MobileSheet title="Playlist options" onClose={() => optionsOpen = false}>
    <div class="mobile-track-actions">
      {#if canEditCover}<button type="button" onclick={() => { coverInputEl?.click(); optionsOpen = false; }}><Image size={21} /> Change Artwork</button>{/if}
      {#if onDeletePlaylist}<button class="danger" type="button" onclick={() => { optionsOpen = false; onDeletePlaylist?.(); }}><Trash2 size={21} /> Delete Playlist</button>{/if}
    </div>
  </MobileSheet>
{/if}
