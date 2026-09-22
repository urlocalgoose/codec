<script lang="ts">
 import { Check, Plus } from "lucide-svelte";
 import MobileSheet from "./MobileSheet.svelte";
 import type {Playlist,Track} from "$lib/types";
 let { track, playlists, selectedIds = $bindable(), saving, onClose, onSave, onCreate }: {track:Track;playlists:Playlist[];selectedIds:string[];saving:boolean;onClose:()=>void;onSave:()=>void;onCreate:()=>void} = $props();
</script>
<div class="native-membership-sheet"><MobileSheet title="Add to Playlist" onClose={onSave}>
  <div class="native-memberships"><p>{track.title}</p><div class="native-form-group">
  {#each playlists as playlist}<label><input type="checkbox" disabled={saving} checked={selectedIds.includes(playlist.id)} onchange={(event) => { selectedIds = event.currentTarget.checked ? [...selectedIds,playlist.id] : selectedIds.filter(id=>id !== playlist.id); }}/><span class="native-choice" class:checked={selectedIds.includes(playlist.id)}>{#if selectedIds.includes(playlist.id)}<Check size={14}/>{/if}</span>{playlist.is_liked ? "Liked Songs" : playlist.name}</label>{/each}
  <button type="button" onclick={onCreate}><Plus size={20}/>New Playlist</button></div></div>
</MobileSheet></div>
