<script lang="ts">
  import { onMount, onDestroy, untrack } from 'svelte';
  import { Check, ChevronDown, LibraryBig, LockKeyhole, Music2, X } from 'lucide-svelte';
  import type { Library, Track } from '$lib/types';
  import { completeAuxLibraryBridge, requestAuxLibraryCopyGrant, type AuxBridgeEnvelope,
    type AuxBridgeResult, type AuxTransferReference } from '$lib/aux-transfer';

  let { envelope, initialToken = '' }: { envelope: AuxBridgeEnvelope; initialToken?: string } = $props();
  let token = $state(untrack(() => initialToken));
  let library = $state<Library | null>(null);
  let busy = $state(false);
  let error = $state('');
  let notice = $state('');
  let search = $state('');
  let selected = $state<Track | null>(null);
  let allowCopy = $state(false);
  let playlistId = $state('');
  let membership = $state<'present' | 'repair' | 'absent' | 'unknown'>('unknown');
  let transferResult = $state<{ status: 'saved' | 'playlist_failed'; playlist_added: boolean } | null>(null);
  let copyGrant: AuxTransferReference | null = null;
  const operationId = crypto.randomUUID();
  const controller = new AbortController();
  const host = $derived(new URL(envelope.return_origin).host);
  const personalHost = typeof window === 'undefined' ? '' : window.location.host;
  const contribution = $derived(envelope.request.kind === 'contribute');
  const playlists = $derived((library?.playlists ?? []).filter((playlist) => !playlist.is_liked));
  const tracks = $derived((library?.tracks ?? []).filter((track) =>
    `${track.title} ${track.artist} ${track.album}`.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase())).slice(0, 150));
  const savedTrack = $derived(library?.tracks.find((track) => track.fingerprint === envelope.request.fingerprint));

  async function request<T>(path: string, body?: unknown): Promise<T> {
    const pending = new AbortController();
    const abort = () => pending.abort();
    if (controller.signal.aborted) abort(); else controller.signal.addEventListener('abort', abort, { once: true });
    const timeout = setTimeout(abort, path === '/api/v2/aux/transfers' ? 70_000 : 12_000);
    try {
      const response = await fetch(path, { method: body === undefined ? 'GET' : 'POST',
        headers: { Authorization: `Bearer ${token.trim()}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
        body: body === undefined ? undefined : JSON.stringify(body), signal: pending.signal,
        cache: 'no-store', credentials: 'omit', redirect: 'error' });
      if (!response.ok) {
        if (response.status === 401 || response.status === 403) throw new Error('Use the owner token for this personal server.');
        let message = 'Your personal server could not complete this request. Try again.';
        try { const result = await response.json(); if (typeof result.error === 'string') message = result.error; } catch { /* Keep a clear connection error. */ }
        throw new Error(message);
      }
      return await response.json() as T;
    } catch (reason) {
      if (pending.signal.aborted && !controller.signal.aborted) throw new Error('Your personal server took too long to respond. Check your connection and retry.');
      throw reason;
    } finally { clearTimeout(timeout); controller.signal.removeEventListener('abort', abort); }
  }

  function report(reason: unknown) {
    if (controller.signal.aborted) return;
    error = reason instanceof Error ? reason.message : 'Could not connect to your personal server. Try again.';
  }
  function finish(result: AuxBridgeResult) {
    try { completeAuxLibraryBridge(envelope, result); } catch (reason) { report(reason); }
  }
  function cancel() {
    controller.abort();
    finish({ type: 'cancelled' });
    window.close();
  }
  async function connect() {
    if (busy || !token.trim()) return;
    busy = true; error = ''; notice = '';
    try {
      const loaded = await request<Library>('/api/v1/library');
      if (!Array.isArray(loaded.tracks) || !Array.isArray(loaded.playlists)) throw new Error('This server did not return a personal library.');
      library = loaded;
      if (!contribution) {
        const result = await request<{ status: 'present' | 'repair' | 'absent' }>(`/api/v2/aux/membership/${encodeURIComponent(envelope.request.fingerprint!)}`);
        if (!['present', 'repair', 'absent'].includes(result.status)) throw new Error('Your library could not be checked. Try again.');
        membership = result.status;
        if (envelope.request.kind === 'membership') finish({ type: 'membership', fingerprint: envelope.request.fingerprint!, status: result.status });
      }
    } catch (reason) { membership = 'unknown'; report(reason); }
    finally { busy = false; }
  }
  async function contribute() {
    if (!selected || busy) return;
    busy = true; error = '';
    try {
      const grant = await request<AuxTransferReference>('/api/v2/aux/grants', {
        fingerprint: selected.fingerprint, session_id: envelope.request.session_id,
        session_origin: envelope.request.session_origin, destination_origin: envelope.request.session_origin, allow_copy: allowCopy,
      });
      finish({ type: 'contribution', fingerprint: selected.fingerprint, grant });
    } catch (reason) { report(reason); }
    finally { busy = false; }
  }
  async function save() {
    if (busy || membership === 'unknown') return;
    busy = true; error = ''; notice = '';
    const fingerprint = envelope.request.fingerprint!;
    try {
      if (membership === 'present' && !transferResult) {
        if (playlistId) await request(`/api/v2/aux/membership/${encodeURIComponent(fingerprint)}/playlist`, { playlist_id: playlistId });
        finish({ type: 'saved', fingerprint, status: 'saved', playlist_added: !!playlistId });
        return;
      }
      if (transferResult && !playlistId) { finish({ type: 'saved', fingerprint, status: 'saved', playlist_added: false }); return; }
      copyGrant ??= await requestAuxLibraryCopyGrant(envelope, controller.signal);
      const result = await request<{ status: 'saved' | 'playlist_failed'; playlist_added: boolean }>('/api/v2/aux/transfers', {
        operation_id: operationId, grant: copyGrant, session_id: envelope.request.session_id,
        session_origin: envelope.request.session_origin, ...(playlistId ? { playlist_id: playlistId } : {}),
      });
      transferResult = result; membership = 'present';
      if (result.status === 'playlist_failed') {
        notice = "Saved to your library. The playlist could not be updated. Choose a playlist and retry, or finish here.";
      } else finish({ type: 'saved', fingerprint, status: 'saved', playlist_added: result.playlist_added });
    } catch (reason) { report(reason); }
    finally { busy = false; }
  }
  onMount(() => { if (token.trim()) void connect(); });
  onDestroy(() => { controller.abort(); token = ''; library = null; });
</script>

<main class="personal-bridge">
  <div class="bridge-card">
    <header>
      <div class="bridge-mark"><LibraryBig size={23} aria-hidden="true" /></div>
      <button class="close" type="button" onclick={cancel} aria-label="Cancel and close personal library"><X size={22} /></button>
    </header>
    <p class="eyebrow">Your personal library</p>
    <h1>{contribution ? 'Choose a song for Aux' : envelope.request.kind === 'membership' ? 'Check your library' : 'Save this song'}</h1>
    <p class="destination">{personalHost}</p>
    <div class="privacy"><LockKeyhole size={17} aria-hidden="true" /><p>Your library and playlists stay here. {contribution ? `Only your selected song is shared with ${host}.` : `This window saves to ${personalHost}.`}</p></div>

    {#if !library}
      <form onsubmit={(event) => { event.preventDefault(); void connect(); }}>
        <label for="personal-token">Owner token for {personalHost}</label>
        <input id="personal-token" type="password" autocomplete="current-password" bind:value={token} disabled={busy} placeholder="Enter your personal server token" />
        <p class="muted">This token is used only on this server and stays in this window.</p>
        <button class="primary" type="submit" disabled={busy || !token.trim()}>{busy ? 'Connecting…' : 'Open your library'}</button>
      </form>
    {:else if membership === 'unknown' && !contribution}
      <p class="muted">{busy ? 'Checking your library…' : 'Your library has not been checked yet.'}</p>
      <button class="primary" type="button" onclick={connect} disabled={busy}>{busy ? 'Checking…' : 'Check your library'}</button>
    {:else if contribution}
      <label for="personal-search">Find a song</label>
      <input id="personal-search" type="search" bind:value={search} placeholder="Title, artist or album" />
      <div class="songs" aria-label="Your personal songs">
        {#each tracks as track (track.fingerprint)}
          <button type="button" class:selected={selected?.fingerprint === track.fingerprint} aria-pressed={selected?.fingerprint === track.fingerprint} onclick={() => { selected = track; }} disabled={busy}>
            <Music2 size={19} aria-hidden="true" /><span><strong>{track.title}</strong><small>{track.artist}</small></span>
            {#if selected?.fingerprint === track.fingerprint}<Check size={19} aria-hidden="true" />{/if}
          </button>
        {:else}<p class="muted">No songs found in your personal library.</p>{/each}
      </div>
      {#if tracks.length === 150}<p class="muted">Search to narrow the song list.</p>{/if}
      <label class="copy-choice"><input type="checkbox" bind:checked={allowCopy} disabled={busy} /><span>Allow others to save this song to their own library</span></label>
      <p class="muted">Listening devices receive audio. This choice controls Codec's save action.</p>
      <button class="primary" type="button" onclick={contribute} disabled={busy || !selected}>{busy ? 'Sharing selected song…' : 'Add selected song to Aux'}</button>
    {:else}
      {#if savedTrack}<div class="song-summary"><Music2 size={22} aria-hidden="true" /><div><strong>{savedTrack.title}</strong><p>{savedTrack.artist}</p></div></div>{/if}
      <p class="membership">{#if membership === 'present'}<Check size={18} aria-hidden="true" /> In your library{:else if membership === 'repair'}The song is in your library, but its audio needs to be restored.{:else}This song is not in your library yet.{/if}</p>
      <label for="personal-playlist">Save destination</label>
      <div class="select-control"><select id="personal-playlist" bind:value={playlistId} disabled={busy}>
        <option value="">Your library</option>
        {#each playlists as playlist (playlist.id)}<option value={playlist.id}>{playlist.name}</option>{/each}
      </select><ChevronDown size={18} aria-hidden="true" /></div>
      <p class="muted">{membership === 'present' ? 'Adding to a playlist keeps your current song and personal edits.' : 'A complete copy is saved here before it is added to your playlist.'}</p>
      <button class="primary" type="button" onclick={save} disabled={busy}>
        {busy ? 'Saving…' : transferResult?.status === 'playlist_failed' ? 'Retry playlist' : playlistId ? 'Add to playlist' : membership === 'present' ? 'Done' : membership === 'repair' ? 'Restore audio' : 'Save to your library'}
      </button>
      {#if transferResult?.status === 'playlist_failed'}<button class="secondary" type="button" disabled={busy} onclick={() => finish({ type: 'saved', fingerprint: envelope.request.fingerprint!, status: 'playlist_failed', playlist_added: false })}>Finish with song saved</button>{/if}
    {/if}
    {#if notice}<p class="message" role="status">{notice}</p>{/if}
    {#if error}<p class="error" role="alert">{error}</p>{/if}
    <button class="cancel" type="button" onclick={cancel}>{busy ? 'Cancel request' : 'Cancel'}</button>
  </div>
</main>

<style>
  .personal-bridge { position:fixed; inset:var(--app-viewport-top,0px) 0 auto; height:var(--app-viewport-height,100dvh); overflow:auto; box-sizing:border-box; background:var(--color-bg,#101010); color:var(--color-text,#fafafa); padding:calc(28px + var(--app-control-safe-top,0px)) 20px calc(28px + var(--app-control-safe-bottom,0px)); }
  .bridge-card { max-width:480px; margin:0 auto; padding-bottom:24px; }
  header { display:flex; justify-content:space-between; align-items:center; gap:16px; }
  .bridge-mark { width:48px; height:48px; display:grid; place-items:center; background:var(--color-panel,#242424); border-radius:14px; }
  .close { background:none; border:0; color:inherit; width:44px; height:44px; display:grid; place-items:center; border-radius:12px; }
  h1 { font-size:29px; line-height:1.15; letter-spacing:-.5px; margin:8px 0; }
  .eyebrow { color:var(--color-muted,#aaa); font-size:12px; font-weight:600; margin:22px 0 0; }
  .destination { font-size:15px; margin:8px 0 20px; overflow-wrap:anywhere; color:var(--color-muted,#aaa); }
  .privacy { display:flex; align-items:flex-start; gap:10px; background:var(--color-panel,#242424); padding:14px; border-radius:14px; margin-bottom:24px; }
  .privacy :global(svg) { flex-shrink:0; margin-top:2px; }
  .privacy p { font-size:13px; line-height:1.5; margin:0; overflow-wrap:anywhere; }
  label { font-size:14px; font-weight:600; display:block; margin:16px 0 9px; }
  input:not([type=checkbox]),select { box-sizing:border-box; width:100%; min-height:48px; padding:12px; font:inherit; font-size:16px; border:1px solid var(--color-border,#444); border-radius:12px; background:var(--color-panel,#242424); color:inherit; }
  .select-control { position:relative; }.select-control select { appearance:none; height:48px; padding-right:42px; }.select-control :global(svg) { position:absolute; right:14px; top:15px; pointer-events:none; }
  button { cursor:pointer; touch-action:manipulation; font:inherit; }
  button:disabled { opacity:.5; cursor:default; }
  .primary,.secondary { box-sizing:border-box; width:100%; min-height:48px; padding:12px 16px; border-radius:13px; border:0; font-weight:600; margin-top:14px; }
  .primary { background:var(--color-accent,#eee); color:var(--button-primary-text,#111); }
  .secondary { background:var(--color-panel,#242424); color:inherit; border:1px solid var(--color-border,#444); }
  .muted { font-size:12px; color:var(--color-muted,#aaa); line-height:1.5; margin:10px 0 16px; }
  .songs { max-height:300px; overflow:auto; margin-top:14px; border:1px solid var(--color-border,#444); border-radius:14px; }
  .songs>button { display:flex; align-items:center; gap:12px; text-align:left; color:inherit; width:100%; min-height:65px; padding:12px; border:0; border-bottom:1px solid var(--color-border,#444); background:transparent; }
  .songs>button:last-child { border-bottom:0; }
  .songs>button.selected { background:var(--color-panel,#242424); }
  .songs>button>span { display:grid; gap:5px; flex:1; min-width:0; }
  .songs strong,.songs small { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .songs strong { font-size:14px; }.songs small { font-size:12px; color:var(--color-muted,#aaa); }
  .songs>p { padding:12px; }
  .copy-choice { display:flex; gap:10px; align-items:flex-start; font-weight:400; font-size:14px; line-height:1.4; margin-top:20px; }
  .copy-choice input { width:18px; height:18px; flex-shrink:0; accent-color:var(--color-accent); }
  .song-summary { display:flex; gap:12px; align-items:center; margin:20px 0; }.song-summary p { margin:5px 0 0; font-size:13px; color:var(--color-muted,#aaa); }
  .membership { display:flex; gap:8px; align-items:center; font-size:14px; line-height:1.5; }
  .message,.error { font-size:14px; line-height:1.5; padding:14px; border-radius:12px; background:var(--color-panel,#242424); }
  .error { color:var(--color-danger,#ff9292); }.cancel { display:block; min-height:44px; padding:10px 16px; margin:12px auto 0; background:none; border:0; color:var(--color-muted,#aaa); }
  button:focus-visible,input:focus-visible,select:focus-visible { outline:2px solid var(--color-accent,#eee); outline-offset:3px; }
</style>
