<script lang="ts">
  import { onDestroy, untrack } from "svelte";
  import { ExternalLink } from "lucide-svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import { auxPath, auxRequest, type AuxConnection, type AuxTrack } from "$lib/aux-v2";
  import { openAuxLibraryBridge, type AuxBridgeResult, type AuxTransferReference } from "$lib/aux-transfer";

  let { connection, kind, track, defaultServer = "", onComplete, onClose }: {
    connection:AuxConnection; kind:"contribute"|"save"; track?:AuxTrack; defaultServer?:string;
    onComplete:(result:AuxBridgeResult)=>void; onClose:()=>void;
  } = $props();
  let server = $state(untrack(() => defaultServer));
  let error = $state(""); let busy = $state(false);
  const controller = new AbortController();
  onDestroy(() => controller.abort());
  function openLibrary() {
    if (busy) return;
    busy = true; error = "";
    const selectedFingerprint = track?.fingerprint;
    try {
      void openAuxLibraryBridge(server, {
        kind, session_id:connection.session_id, session_origin:connection.server,
        ...(selectedFingerprint ? {fingerprint:selectedFingerprint} : {})
      }, {
        signal:controller.signal,
        requestGrant:async (fingerprint:string, destinationOrigin:string) => {
          if (kind !== "save" || fingerprint !== selectedFingerprint || controller.signal.aborted) throw new Error("This song is no longer selected.");
          return auxRequest<AuxTransferReference>(connection.server,
            `${auxPath(connection)}/tracks/${encodeURIComponent(fingerprint)}/copy-grant`,
            connection.token, {destination_origin:destinationOrigin}, undefined, controller.signal);
        }
      }).then(result => { if (!controller.signal.aborted) {onComplete(result);onClose();} })
        .catch(reason => {if (!controller.signal.aborted) error = reason instanceof Error ? reason.message : String(reason);})
        .finally(() => busy = false);
    } catch (reason) { error = reason instanceof Error ? reason.message : String(reason); busy = false; }
  }
</script>

<MobileSheet title={kind === "contribute" ? "Your library" : "Save to your library"} {onClose}>
  <form class="aux-personal-form" onsubmit={event => {event.preventDefault();openLibrary();}}>
    {#if track}<div><strong>{track.title}</strong><p>{track.artist}</p></div>{/if}
    <p>Open your own Codec server to {kind === "contribute" ? "choose a song to add" : "check your library and choose a playlist"}.</p>
    <label>Your server<input type="url" bind:value={server} placeholder="https://your-server.example" autocomplete="url" autocapitalize="none" autocorrect="off" required/></label>
    <small>You’ll sign in on your server. Your auth token and playlists stay there.</small>
    {#if error}<p role="alert" class="aux-personal-error">{error}</p>{/if}
    <button class="ui-button primary" disabled={busy || !server.trim()}><ExternalLink size={18}/>{busy ? "Waiting for your library…" : "Open your library"}</button>
    <a href="https://codec.codie.sh/docs/hosting.html" target="_blank" rel="noopener noreferrer">Set up your own server ↗</a>
  </form>
</MobileSheet>

<style>
  .aux-personal-form{display:grid;gap:18px;padding:20px 24px 32px;color:var(--color-text);}
  label{display:grid;gap:8px;font-weight:600;}input{width:100%;box-sizing:border-box;border-radius:12px;padding:15px;border:1px solid var(--color-border);background:var(--color-panel);color:var(--color-text);font:inherit;}
  p,small{margin:0;color:var(--color-muted);line-height:1.5;}strong{display:block;margin-bottom:5px;}a{min-height:44px;display:flex;align-items:center;color:var(--color-accent);}.aux-personal-error{color:var(--color-danger);}
</style>
