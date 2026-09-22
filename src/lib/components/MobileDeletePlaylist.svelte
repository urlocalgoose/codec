<script lang="ts">
  import { onMount } from "svelte";
  import { cubicOut } from "svelte/easing";
  import { scale, type TransitionConfig } from "svelte/transition";
  import type { Playlist } from "$lib/types";

  let { playlist, onDelete, onClose, returnFocus }: {
    playlist: Playlist;
    onDelete: (playlist: Playlist) => Promise<void>;
    onClose: () => void;
    returnFocus?: (playlistID: string) => void;
  } = $props();
  let dialog: HTMLDialogElement;
  let cancelButton: HTMLButtonElement;
  let busy = $state(false);
  let error = $state("");
  let presented = $state(false);
  let leaving = $state(false);
  let mounted = false;

  function alertMotion(node: HTMLDialogElement, { duration }: { duration: number }): TransitionConfig {
    return scale(node, { start: .96, duration: matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : duration, easing: cubicOut });
  }
  onMount(() => {
    mounted = true;
    const trigger = document.activeElement as HTMLElement | null;
    const playlistID = playlist.id;
    dialog.showModal();
    cancelButton.focus({ preventScroll: true });
    let frame = requestAnimationFrame(() => { frame = requestAnimationFrame(() => { presented = true; }); });
    return () => {
      mounted = false;
      cancelAnimationFrame(frame);
      dialog.close();
      if (trigger?.isConnected) trigger.focus({ preventScroll: true });
      else returnFocus?.(playlistID);
    };
  });
  async function confirmDelete() {
    if (busy || playlist.is_liked) return;
    busy = true;
    error = "";
    try {
      await onDelete(playlist);
      if (mounted) onClose();
    } catch (failure) {
      if (mounted) error = failure instanceof Error ? failure.message : "Could not delete playlist. Try again.";
    } finally {
      if (mounted) busy = false;
    }
  }
</script>

<dialog class="native-alert" class:sheet-presented={presented} class:sheet-leaving={leaving} bind:this={dialog}
  in:alertMotion={{ duration: 200 }} out:alertMotion={{ duration: 140 }} onoutrostart={() => { leaving = true; }}
  aria-labelledby="delete-playlist-title" aria-describedby="delete-playlist-description" aria-busy={busy}
  oncancel={(event) => { event.preventDefault(); if (!busy) onClose(); }}>
  <form onsubmit={(event) => { event.preventDefault(); void confirmDelete(); }}>
    <div class="native-alert-body">
      <h2 id="delete-playlist-title">Delete Playlist?</h2>
      <p class="native-alert-description" id="delete-playlist-description">Delete “{playlist.name}”? Its songs will stay in your library.</p>
      {#if error}<p role="alert">{error}</p>{/if}
    </div>
    <div class="native-alert-actions">
      <button bind:this={cancelButton} type="button" disabled={busy} onclick={onClose}>Cancel</button>
      <button class="destructive" type="submit" disabled={busy || playlist.is_liked}>{busy ? "Deleting…" : "Delete"}</button>
    </div>
  </form>
</dialog>
