<script lang="ts">
  import ImportProgress from "./ImportProgress.svelte";
  import type { ImportPhase } from "$lib/import-job";
  import type { ImportJobStatus } from "$lib/sync";
  import { Radio, QrCode, Users, Upload } from "lucide-svelte";
  import MobileSheet from "./MobileSheet.svelte";
  let { importPhase, importFraction, importJob, importMessage, importConnectionError, onCancelImport, onRetryImport, onDismissImport, server = $bindable(), token = $bindable(), connected, loading, error, auxCode, auxBusy, guestMode, importing, syncMessage, onImportFiles, onClose, onReconnect, onDisconnect, onStartAux, onShowAux, onEndAux, onJoinAux }: {
    server:string; token:string; connected:boolean; loading:boolean; error:string; auxCode:string; auxBusy:boolean; guestMode:boolean;
    importPhase:ImportPhase; importFraction:number; importJob:ImportJobStatus|null; importMessage:string; importConnectionError:string;
    onCancelImport:()=>void; onRetryImport:()=>void; onDismissImport:()=>void;
    importing:boolean; syncMessage:string; onImportFiles:(files:File[])=>void;
    onClose:()=>void; onReconnect:()=>void; onDisconnect:()=>void; onStartAux:()=>void; onShowAux:()=>void; onEndAux:()=>void; onJoinAux:(code:string)=>void;
  } = $props();
  let joining = $state(false); let code = $state("");
  let importInput: HTMLInputElement | undefined = $state();
  function importPicked(event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    const files = input.files ? [...input.files] : [];
    input.value = "";
    if (files.length) onImportFiles(files);
  }
</script>
<MobileSheet full title="Settings" {onClose}>
  <div class="native-settings">
    <section><h3>Sync server</h3><div class="native-form-group">
      <input aria-label="Server address" type="url" bind:value={server} placeholder="https://your-server or 192.168.1.20:8787" autocapitalize="none" spellcheck="false" />
      <input aria-label="Auth token" type="password" bind:value={token} placeholder="Auth token" autocomplete="off" />
    </div></section>
    <section><h3>Aux</h3><div class="native-form-group">
      {#if auxCode}<button type="button" onclick={onShowAux}><Radio size={27}/><span>{guestMode ? "Joined Aux" : "Aux Live"}</span><strong>{auxCode}</strong></button>
        <button class="destructive" type="button" disabled={auxBusy} onclick={onEndAux}>{guestMode ? "Leave Aux" : "End Aux"}</button>
      {:else}<button type="button" disabled={auxBusy || !connected} onclick={onStartAux}><QrCode size={25}/>Start Aux</button>{/if}
      <button type="button" onclick={() => joining = true}><Users size={28}/>Join Aux</button>
    </div><p>Guests can browse, stream, and control the shared queue. They can't change your library.</p></section>
    {#if !guestMode}
      <section><h3>Library</h3><div class="native-form-group">
        <button type="button" disabled={importing || !connected} onclick={() => importInput?.click()}><Upload size={25}/>{importing ? "Importing…" : "Import music"}</button>
        <input bind:this={importInput} type="file" accept=".mp3,audio/mpeg,.m4a,audio/mp4,.flac,audio/flac,.wav,audio/wav,.json,application/json,.jpg,.jpeg,.png,image/jpeg,image/png,.zip,application/zip" multiple hidden onchange={importPicked}/>
      </div>
      <ImportProgress phase={importPhase} fraction={importFraction} job={importJob} message={importMessage} connectionError={importConnectionError} onCancel={onCancelImport} onRetry={onRetryImport} onDismiss={onDismissImport}/>
      {#if importPhase === "idle"}<p>{syncMessage || "Choose a bundle ZIP to include its audio, playlists, and covers, or select MP3 files."}</p>{/if}</section>
    {/if}
    <section><div class="native-form-group"><button type="button" disabled={loading || !server.trim()} onclick={onReconnect}>{loading ? "Connecting…" : "Reconnect"}</button><button class="destructive" type="button" onclick={onDisconnect}>Disconnect</button></div>
    <p role="status">{connected ? "Connected" : "Offline"}{error ? ` · ${error}` : ""}</p></section>
  </div>
</MobileSheet>
{#if joining}<MobileSheet title="Join Aux" onClose={() => joining = false}><form class="mobile-create-playlist" onsubmit={(event) => { event.preventDefault(); joining = false; onJoinAux(code.trim()); }}><label>Invitation link<input bind:value={code} placeholder="Paste an Aux invitation link" autocapitalize="none" autocorrect="off" /></label><button class="ui-button primary" disabled={!code.trim()}>Join Aux</button></form></MobileSheet>{/if}
