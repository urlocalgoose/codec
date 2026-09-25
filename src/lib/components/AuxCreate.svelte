<script lang="ts">
  import { untrack } from "svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import type { Library } from "$lib/types";
  import { auxRequest, type AuxCreated, type AuxMode } from "$lib/aux-v2";
  let { library, server, token, deviceId, currentFingerprint, currentPlaylist, onCreated, onClose }: {
    library: Library; server:string; token:string; deviceId:string; currentFingerprint:string; currentPlaylist:string;
    onCreated:(created:AuxCreated)=>void; onClose:()=>void;
  } = $props();
  let mode = $state<AuxMode>("shared_speaker");
  let playlist = $state(untrack(() => currentPlaylist || ""));
  let allowSaves = $state(false); let allowContributions = $state(false);
  let name = $state("Codec Aux"); let busy = $state(false); let error = $state("");
  const selected = $derived(library.playlists.find(value => value.id === playlist));
  const tracks = $derived(playlist === "all" ? library.tracks : selected ? library.tracks.filter(track => selected.track_ids.includes(track.id)) : []);
  const containsCurrent = $derived(!currentFingerprint || tracks.some(track => track.fingerprint === currentFingerprint));
  async function start() {
    if (busy || !tracks.length || !containsCurrent || tracks.length > 10000) return;
    busy = true; error = "";
    try { onCreated(await auxRequest<AuxCreated>(server,"/api/v2/aux/sessions",token, { mode, host_device_id:deviceId, host_name:name.trim() || "Codec Aux", catalog_fingerprints:tracks.map(t=>t.fingerprint), allow_saves:allowSaves, allow_contributions:allowContributions })); }
    catch (reason) { error = reason instanceof Error ? reason.message : String(reason); }
    finally { busy = false; }
  }
</script>
<MobileSheet title="Start Aux" onClose={() => { if (!busy) onClose(); }}>
  <form class="aux-create" onsubmit={(event) => { event.preventDefault(); void start(); }}>
    <fieldset><legend>Where are you listening?</legend>
      <label class="aux-mode"><input type="radio" value="shared_speaker" bind:group={mode}/><span><strong>Shared speaker</strong><small>Everyone controls the host’s speaker.</small></span></label>
      <label class="aux-mode"><input type="radio" value="listen_together" bind:group={mode}/><span><strong>Listen together</strong><small>Everyone listens on their own device.</small></span></label>
    </fieldset>
    <label>Session name<input bind:value={name} maxlength="40"/></label>
    <label>Music to share<select bind:value={playlist}><option value="" disabled>Choose a playlist</option>{#each library.playlists.filter(p=>!p.is_liked) as item}<option value={item.id}>{item.name}</option>{/each}<option value="all">All songs</option></select></label>
    <p>{tracks.length} songs. Guests won’t see your playlists, likes, or listening history.</p>
    {#if tracks.length > 10000}<p class="aux-create-error">Choose a playlist with at most 10,000 songs.</p>{/if}
    {#if !containsCurrent}<p class="aux-create-error">Choose music that includes the playing song, or pause and choose another song first.</p>{/if}
    <label class="aux-toggle"><input type="checkbox" bind:checked={allowContributions}/><span>Let guests add songs from their own servers</span></label>
    <label class="aux-toggle"><input type="checkbox" bind:checked={allowSaves}/><span>Let participants save shared songs to their libraries</span></label>
    {#if allowSaves}<p>Enable this only for music you’re allowed to share.</p>{/if}
    {#if error}<p class="aux-create-error" role="alert">{error}</p>{/if}
    <button class="ui-button primary" disabled={busy || !tracks.length || !containsCurrent || tracks.length > 10000}>{busy ? "Starting…" : "Start Aux"}</button>
  </form>
</MobileSheet>
<style>
  .aux-create { display:grid; gap:18px; padding:20px 24px 32px; color:var(--color-text); }
  fieldset { border:0; padding:0; margin:0; display:grid; gap:10px; } legend { margin-bottom:12px; font-weight:700; }
  label { display:grid; gap:8px; } input:not([type]),select { background:var(--color-panel); color:var(--color-text); border:1px solid var(--color-border); border-radius:12px; padding:14px; font:inherit; width:100%; }
  .aux-mode,.aux-toggle { display:flex; gap:12px; align-items:center; min-height:44px; } .aux-mode { padding:14px; border:1px solid var(--color-border); border-radius:16px; }
  .aux-mode span { display:grid; gap:4px; } input[type] { accent-color:var(--color-accent); width:20px; height:20px; flex-shrink:0; }
  p,small { color:var(--color-muted); font-size:13px; line-height:1.5; margin:0; } .aux-create-error { color:var(--color-danger); }
</style>
