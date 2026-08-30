<script lang="ts">
  import { Check, Image, LoaderCircle, Pencil, X } from "lucide-svelte";
  import type { Playlist } from "$lib/types";

  let {
    viewTitle,
    viewSubtitle,
    selectedPlaylist,
    isEditing,
    renaming,
    canEditCover = false,
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
    playlistNameDraft: string;
    onStartRename: (playlist: Playlist) => void;
    onCommitRename: () => void;
    onCancelRename: () => void;
    onChangeCover?: (file: File) => void;
  } = $props();

  let nameInputEl: HTMLInputElement | undefined = $state();
  let coverInputEl: HTMLInputElement | undefined = $state();

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
