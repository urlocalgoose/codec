<script lang="ts">
  import type { AuxBridgeResult } from "$lib/aux-transfer";
  import { onMount, untrack } from "svelte";
  import { Copy, GripVertical, Headphones, ListMusic, LogOut, Pause, Play, Plus, Radio, RefreshCw, Settings2, SkipForward, Trash2, UserMinus, VolumeX, X } from "lucide-svelte";
  import QRCode from "qrcode";
  import MobileSheet from "./MobileSheet.svelte";
  import VirtualRows from "./VirtualRows.svelte";
  import MobileSwipeRow from "./MobileSwipeRow.svelte";
  import { formatDuration } from "$lib/library";
  import { AuxError, auxRequest, auxPath, auxMediaURL, auxCanListen, auxCanRemove, auxPosition, auxInviteLink, type AuxConnection, type AuxState, type AuxTrack, type AuxCreated } from "$lib/aux-v2";
  let { connection, initialState, invite = "", audio, deviceId, inheritedFingerprint = "", onPrepareAudio, onLeave, onPersonalAction }: {
    connection:AuxConnection; initialState:AuxState|null; invite?:string; audio:HTMLAudioElement;
    deviceId:string; inheritedFingerprint?:string; onPrepareAudio:()=>void; onLeave:()=>void;
    onPersonalAction:(kind:"contribute"|"save",track?:AuxTrack)=>void;
  } = $props();
  let session = $state<AuxState|null>(untrack(() => initialState));
  let secret = $state(untrack(() => invite)); let query = $state(""); let catalog = $state<AuxTrack[]>([]);
  let tab = $state<"queue"|"music">("queue"); let manage = $state(false);
  let error = $state(""); let notice = $state(""); let unavailable = $state(false); let busy = $state(false);
  let listener = $state(false); let progress = $state(0); let receivedAt = performance.now();
  let qr = $state(""); let dragId = $state(""); let dropId = $state(""); let openedSwipe = $state<string|null>(null);
  let scroller:HTMLElement;
  let stopped = false; let pollTimer:ReturnType<typeof setTimeout>; let pollController:AbortController|null = null; let refreshPending = false;
  let events:EventSource|null = null; let eventsURL = "";
  let loadedFingerprint = ""; let expectedPause = 0; let playbackGeneration = 0;
  const canListen = $derived(session ? auxCanListen(session,deviceId) : false);
  const modeLabel = $derived(session?.mode === "listen_together" ? "Listen together" : "Shared speaker");
  const rows = $derived(catalog.filter(track => `${track.title} ${track.artist} ${track.album}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())));
  const link = $derived(secret ? auxInviteLink(connection.server,secret) : "");
  $effect(() => { const value=link; let active=true; if(value) void QRCode.toDataURL(value,{width:240,margin:2,color:{dark:"#111111",light:"#ffffff"}}).then(url=>{if(active)qr=url;}); else qr="";return()=>{active=false;}; });

  export async function personalResult(result:AuxBridgeResult) {
    if(result.type === "contribution") await command("append",{fingerprint:result.fingerprint,grant:result.grant});
    else if(result.type === "saved") notice=result.status==="playlist_failed"?"Saved to your library, but the playlist couldn't be updated.":result.playlist_added?"Saved to your playlist":"Saved to your library";
  }
  function pauseLocal() { if (!audio.paused) { expectedPause++; audio.pause(); } }
  function showError(reason:unknown) { error = reason instanceof Error ? reason.message : String(reason); }
  function sessionGone(reason:unknown) {
    if (!(reason instanceof AuxError) || ![401,403,404,410].includes(reason.status)) return false;
    events?.close(); events=null;
    unavailable = true; listener=false; pauseLocal(); audio.removeAttribute("src"); audio.load(); return true;
  }
  function apply(next:AuxState, elapsed = 0) {
    if (stopped || next.session_id!==connection.session_id || next.schema!=="codec.aux.v2") return;
    if (session && next.revision<session.revision) return;
    session=next; receivedAt=performance.now()-Math.min(elapsed/2,500);
    progress=auxPosition(next,receivedAt);
    startEvents();
    void reconcileAudio();
  }
  function startEvents() {
    const token=connection.role==="host"?session?.media_token:connection.token;
    if(stopped||unavailable||!token||typeof EventSource==="undefined")return;
    const url=new URL(auxPath(connection)+"/events",connection.server);url.searchParams.set("access_token",token);
    if(events&&eventsURL===url.href&&events.readyState!==2)return;
    events?.close();eventsURL=url.href;const source=new EventSource(url.href);events=source;
    source.addEventListener("aux_changed",()=>{if(events===source)void refresh();});
    source.addEventListener("ended",()=>{if(events!==source)return;error="This Aux session or your access has ended.";sessionGone(new AuxError(error,410));});
    source.onerror=()=>{if(events===source&&!stopped)void refresh();};
  }
  async function reconcileAudio() {
    const snapshot=session, generation=++playbackGeneration;
    if (!snapshot || !listener || !auxCanListen(snapshot,deviceId) || unavailable) { pauseLocal(); return; }
    const current=snapshot.current;
    if (!current) { pauseLocal(); return; }
    const source=auxMediaURL(connection,snapshot,current.track.media_url);
    if (!source) { error="This song has no authorized audio source.";pauseLocal();return; }
    if(loadedFingerprint!==current.track.fingerprint || audio.error) {
      loadedFingerprint=current.track.fingerprint;pauseLocal();audio.src=source;audio.load();
    }
    const position=auxPosition(snapshot,receivedAt);
    if(audio.readyState>=1 && Math.abs(audio.currentTime-position)>1.25) audio.currentTime=position;
    if(snapshot.status!=="playing") { pauseLocal();return; }
    if(audio.paused) {
      try { onPrepareAudio();await audio.play();if(stopped || !listener || loadedFingerprint!==current.track.fingerprint) pauseLocal(); }
      catch { if(!stopped && generation===playbackGeneration) {listener=false;notice="Tap Listen on this device to continue.";} }
    }
    updateMediaSession();
  }
  function updateMediaSession() {
    if (!("mediaSession" in navigator) || !session || !listener || !canListen) return;
    const track=session.current?.track;
    navigator.mediaSession.playbackState=session.status==="playing"?"playing":"paused";
    navigator.mediaSession.metadata=track && typeof MediaMetadata!=="undefined"?new MediaMetadata({title:track.title,artist:track.artist,album:track.album}):null;
  }
  async function refresh() {
    if(stopped || unavailable) return;
    if(pollController) {refreshPending=true;return;}
    clearTimeout(pollTimer); const controller=new AbortController();pollController=controller;
    const start=performance.now();
    try { const next=await auxRequest<AuxState>(connection.server,auxPath(connection)+"/state",connection.token,undefined,undefined,controller.signal);if(!controller.signal.aborted) {error="";apply(next,performance.now()-start);} }
    catch(reason) {if(!controller.signal.aborted){showError(reason);sessionGone(reason);}}
    finally {if(pollController===controller)pollController=null;if(!stopped&&!unavailable){const delay=refreshPending?0:events?.readyState===1?20000:document.hidden?5000:1500;refreshPending=false;pollTimer=setTimeout(()=>void refresh(),delay);}}
  }
  async function command(kind:string, fields:Record<string,unknown>={}) {
    if(!session || busy || unavailable)return;busy=true;error="";notice="";
    const body={command_id:crypto.randomUUID(),kind,...(["next","reorder"].includes(kind)?{expected_revision:session.revision}:{}),...fields};
    try {
      let next:AuxState;
      try {next=await auxRequest<AuxState>(connection.server,auxPath(connection)+"/commands",connection.token,body);}
      catch(reason) {
        if(reason instanceof AuxError && reason.status!==0 && reason.status<500)throw reason;
        // Retry only an uncertain delivery, with the identical idempotency key.
        next=await auxRequest<AuxState>(connection.server,auxPath(connection)+"/commands",connection.token,body);
      }
      apply(next);if(kind==="append")notice="Added to queue";
    }catch(reason){showError(reason);if(!sessionGone(reason))void refresh();}
    finally{busy=false;}
  }
  function toggleListening() {
    if(!canListen)return;
    listener=!listener;notice="";
    if(!listener){pauseLocal();return;}
    onPrepareAudio();
    // Use the existing media element directly in this gesture for Safari.
    const track=session?.current?.track;
    if(track&&session&&(loadedFingerprint!==track.fingerprint || audio.error)){loadedFingerprint=track.fingerprint;audio.src=auxMediaURL(connection,session,track.media_url);audio.load();}
    if(session?.status==="playing")void audio.play().catch(()=>{listener=false;notice="Audio could not start. Tap Listen on this device to retry.";});
    void reconcileAudio();
  }
  function move(id:string,target:string) {
    if(!session || id===target || busy)return;
    const ids=session.queue.map(entry=>entry.entry_id),from=ids.indexOf(id),to=ids.indexOf(target);
    if(from<0||to<0)return;ids.splice(to,0,ids.splice(from,1)[0]);void command("reorder",{entry_ids:ids});
  }
  function dragStart(event:PointerEvent,id:string) {
    if(busy||event.button!==0)return;
    event.preventDefault();event.stopPropagation();dragId=id;dropId=id;
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  }
  function dragMove(event:PointerEvent) {
    if(!dragId)return;event.preventDefault();
    const row=document.elementFromPoint(event.clientX,event.clientY)?.closest<HTMLElement>("[data-aux-entry]");
    if(row?.dataset.auxEntry)dropId=row.dataset.auxEntry;
    const bounds=scroller.getBoundingClientRect();if(event.clientY<bounds.top+90)scroller.scrollTop-=14;else if(event.clientY>bounds.bottom-80)scroller.scrollTop+=14;
  }
  function dragEnd() {if(dragId&&dropId)move(dragId,dropId);dragId="";dropId="";}
  async function end() {
    if(busy)return;busy=true;
    try {if(!unavailable)await auxRequest<void>(connection.server,auxPath(connection)+(connection.role==="guest"?`/members/${encodeURIComponent(connection.participant_id)}`:""),connection.token,undefined,"DELETE");pauseLocal();onLeave();}
    catch(reason){if(sessionGone(reason))onLeave();else showError(reason);}
    finally{busy=false;}
  }
  async function removeMember(id:string) {
    try {await auxRequest<void>(connection.server,auxPath(connection)+`/members/${encodeURIComponent(id)}`,connection.token,undefined,"DELETE");void refresh();}catch(reason){showError(reason);}
  }
  async function rotateInvite(revoke=false) {
    try {const result=await auxRequest<Pick<AuxCreated,"invite_secret"|"invite_expires_at">>(connection.server,auxPath(connection)+"/invite",connection.token,revoke?undefined:{},revoke?"DELETE":"POST");secret=revoke?"":result.invite_secret;notice=revoke?"Invitation revoked. Current participants can stay.":"New invitation ready. The previous link no longer works.";}
    catch(reason){showError(reason);}
  }
  async function copyLink() {try{await navigator.clipboard.writeText(link);notice="Invitation copied";}catch{notice="Copy the invitation link below.";}}
  onMount(()=>{
    if(connection.role==="host"&&session&&auxCanListen(session,deviceId)&&!audio.paused&&session.current?.track.fingerprint===inheritedFingerprint){loadedFingerprint=inheritedFingerprint;listener=true;}
    else {pauseLocal();audio.removeAttribute("src");audio.load();}
    const interrupted=()=>{if(expectedPause){expectedPause--;return;}if(!audio.ended&&session?.status==="playing"){listener=false;notice="Playback stopped on this device. The Aux session is still playing.";}};
    const loaded=()=>{if(session&&listener)audio.currentTime=auxPosition(session,receivedAt);};
    const ended=()=>{void refresh();};const failed=()=>{listener=false;notice="Audio couldn't load on this device. Check your connection, then listen again.";};
    const foreground=()=>{if(!document.hidden)void refresh();};
    audio.addEventListener("pause",interrupted);audio.addEventListener("loadedmetadata",loaded);audio.addEventListener("ended",ended);audio.addEventListener("error",failed);
    document.addEventListener("visibilitychange",foreground);window.addEventListener("online",foreground);
    void refresh();void auxRequest<{tracks:AuxTrack[]}>(connection.server,auxPath(connection)+"/catalog",connection.token).then(result=>{if(!stopped)catalog=result.tracks;}).catch(reason=>{if(!stopped)showError(reason);});
    const clock=setInterval(()=>{if(session&&!document.hidden)progress=auxPosition(session,receivedAt);},500);
    if("mediaSession"in navigator)for(const [action,kind]of[["play","resume"],["pause","pause"],["nexttrack","next"]]as const)try{navigator.mediaSession.setActionHandler(action,()=>void command(kind));}catch{/* Optional browser controls. */}
    return()=>{stopped=true;events?.close();events=null;playbackGeneration++;clearTimeout(pollTimer);clearInterval(clock);pollController?.abort();pauseLocal();
      audio.removeEventListener("pause",interrupted);audio.removeEventListener("loadedmetadata",loaded);audio.removeEventListener("ended",ended);audio.removeEventListener("error",failed);
      document.removeEventListener("visibilitychange",foreground);window.removeEventListener("online",foreground);
      if("mediaSession"in navigator){for(const action of["play","pause","nexttrack"]as const)try{navigator.mediaSession.setActionHandler(action,null);}catch{}navigator.mediaSession.metadata=null;navigator.mediaSession.playbackState="none";}
    };
  });
</script>

<main class="aux-workspace" bind:this={scroller}>
  <header class="aux-header"><div><span><Radio size={15}/>{modeLabel}</span><h1>{session?.host_name || "Aux"}</h1></div><div>{#if connection.role==="host"}<button class="aux-icon" aria-label="Manage Aux" onclick={()=>manage=true}><Settings2 size={23}/></button>{/if}<button class="aux-icon" aria-label={connection.role==="host"?"End Aux":"Leave Aux"} onclick={()=>connection.role==="host"?manage=true:void end()}><LogOut size={23}/></button></div></header>
  {#if error}<div class="aux-status" role="alert"><p>{error}</p>{#if unavailable}<button class="ui-button" onclick={onLeave}>Return to Codec</button>{:else}<button class="aux-icon" aria-label="Check connection" onclick={()=>void refresh()}><RefreshCw size={19}/></button>{/if}</div>{/if}
  {#if notice}<p class="aux-notice" role="status">{notice}</p>{/if}
  {#if session}
    <section class="aux-playing" aria-label="Now playing">
      {#if session.current}{@const track=session.current.track}<div class="aux-cover">{#if track.artwork_url}<img src={auxMediaURL(connection,session,track.artwork_url)} alt="" referrerpolicy="no-referrer" onerror={event=>{(event.currentTarget as HTMLImageElement).style.visibility="hidden";}}/>{:else}<ListMusic size={48}/>{/if}</div>
        <div class="aux-song"><div><h2>{track.title}</h2><p>{track.artist}</p></div><button class="aux-icon" aria-label={`Save ${track.title} to your library`} onclick={()=>onPersonalAction("save",track)}><Plus size={24}/></button></div>
        <div class="aux-progress"><progress max={track.duration_seconds||1} value={progress} aria-label="Song position"></progress><span>{formatDuration(progress)}<span>{formatDuration(track.duration_seconds)}</span></span></div>
      {:else}<div class="aux-empty-playing"><ListMusic size={32}/><h2>Add a song to get started</h2></div>{/if}
      <div class="aux-transport"><button class="aux-play" disabled={busy||unavailable||(!session.current&&!session.queue.length)} aria-label={session.status==="playing"?"Pause Aux":"Resume Aux"} onclick={()=>void command(session?.status==="playing"?"pause":"resume")}>{#if session.status==="playing"}<Pause size={30} fill="currentColor"/>{:else}<Play size={30} fill="currentColor"/>{/if}</button><button class="aux-icon" disabled={busy||unavailable||!session.current} aria-label="Skip song" onclick={()=>void command("next")}><SkipForward size={28} fill="currentColor"/></button></div>
      {#if canListen}<button class="aux-listen" disabled={unavailable||!session.current} onclick={toggleListening}>{#if listener}<VolumeX size={18}/>Mute this device{:else}<Headphones size={18}/>Listen on this device{/if}</button>{:else}<p class="aux-speaker-note">Music plays on the host’s selected speaker.</p>{/if}
    </section>
    <nav class="aux-tabs" aria-label="Aux views"><button aria-current={tab==="queue"?"page":undefined} onclick={()=>tab="queue"}>Up next <span>{session.queue.length}</span></button><button aria-current={tab==="music"?"page":undefined} onclick={()=>tab="music"}>Shared music</button></nav>
    {#if tab==="queue"}
      <section class="aux-queue" aria-label="Upcoming queue">
        {#if !session.queue.length}<p class="aux-empty">The queue is empty. Choose a song from Shared music.</p>{/if}
        {#each session.queue as entry (entry.entry_id)}
          <div data-aux-entry={entry.entry_id} class:aux-drop={dropId===entry.entry_id}>
            <MobileSwipeRow identity={entry.entry_id} disabled={busy||unavailable} trailing={auxCanRemove(session,entry)?[{id:"remove",icon:"remove",label:"Remove",run:()=>void command("remove",{entry_id:entry.entry_id})}]:[]} openSide={openedSwipe===entry.entry_id?"trailing":null} onOpenChange={side=>openedSwipe=side?entry.entry_id:null}>
              <div class="aux-row"><div class="aux-thumb">{#if entry.track.artwork_url}<img src={auxMediaURL(connection,session,entry.track.artwork_url)} alt="" loading="lazy" referrerpolicy="no-referrer"/>{/if}</div><div class="aux-row-copy"><strong>{entry.track.title}</strong><small>{entry.track.artist}{entry.participant_id===session.participant_id?" · Your request":""}</small></div>
                {#if auxCanRemove(session,entry)}<button class="aux-icon aux-remove" disabled={busy||unavailable} aria-label={`Remove ${entry.track.title}`} onclick={()=>void command("remove",{entry_id:entry.entry_id})}><X size={17}/></button>{/if}
                <button class="aux-icon aux-grip" disabled={busy||unavailable} aria-label={`Move ${entry.track.title}; use arrow keys or drag`} onpointerdown={event=>dragStart(event,entry.entry_id)} onpointermove={dragMove} onpointerup={dragEnd} onpointercancel={()=>{dragId="";dropId="";}} onkeydown={event=>{if(session&&(event.key==="ArrowUp"||event.key==="ArrowDown")){event.preventDefault();const index=session.queue.findIndex(e=>e.entry_id===entry.entry_id);const target=session.queue[index+(event.key==="ArrowUp"?-1:1)];if(target)move(entry.entry_id,target.entry_id);}}}><GripVertical size={20}/></button>
              </div>
            </MobileSwipeRow>
          </div>
        {/each}
      </section>
    {:else}
      <section class="aux-catalog" aria-label="Shared music"><input type="search" bind:value={query} placeholder="Search shared music" aria-label="Search shared music"/>
        {#if session.allow_contributions}<button class="aux-personal" onclick={()=>onPersonalAction("contribute")}><Plus size={19}/>Add from your library</button>{/if}
        <VirtualRows items={rows} rowHeight={74}>{#snippet children(track)}<MobileSwipeRow identity={`catalog:${track.fingerprint}`} leading={[{id:"queue",icon:"last",label:"Add to queue",run:()=>void command("append",{fingerprint:track.fingerprint})}]} disabled={busy||unavailable} openSide={openedSwipe===track.fingerprint?"leading":null} onOpenChange={side=>openedSwipe=side?track.fingerprint:null}><div class="aux-row"><div class="aux-thumb">{#if track.artwork_url}<img src={auxMediaURL(connection,session!,track.artwork_url)} alt="" loading="lazy" referrerpolicy="no-referrer"/>{/if}</div><div class="aux-row-copy"><strong>{track.title}</strong><small>{track.artist}</small></div><button class="aux-icon" disabled={busy||unavailable} aria-label={`Add ${track.title} to queue`} onclick={()=>void command("append",{fingerprint:track.fingerprint})}><ListMusic size={22}/></button><button class="aux-icon" aria-label={`Save ${track.title} to your library`} onclick={()=>onPersonalAction("save",track)}><Plus size={22}/></button></div></MobileSwipeRow>{/snippet}</VirtualRows>
      </section>
    {/if}
  {:else}<p>Connecting to Aux…</p>{/if}
</main>
{#if manage&&session}<MobileSheet full title="Manage Aux" onClose={()=>manage=false}><div class="aux-management">
  <p>{modeLabel} · Sessions last up to 24 hours.</p>
  {#if link}<img class="aux-qr" src={qr} alt="Aux invitation QR code"/><button class="ui-button primary" onclick={()=>void copyLink()}><Copy size={18}/>Copy invitation</button><input readonly value={link} aria-label="Aux invitation link"/><p>Invitations expire after 15 minutes.</p>{/if}
  <div class="aux-invite-actions"><button class="ui-button" onclick={()=>void rotateInvite()}>New invitation</button>{#if secret}<button class="ui-button" onclick={()=>void rotateInvite(true)}>Revoke invitation</button>{/if}</div>
  <h3>Participants</h3>{#each session.members??[] as member (member.participant_id)}<div class="aux-member"><span>{member.display_name||"Guest"}</span><button class="aux-icon" aria-label={`Remove ${member.display_name||"guest"}`} onclick={()=>void removeMember(member.participant_id)}><UserMinus size={20}/></button></div>{/each}
  {#if !session.members?.length}<p>No guests yet.</p>{/if}
  <button class="ui-button aux-end" disabled={busy} onclick={()=>void end()}><Trash2 size={18}/>End Aux for everyone</button>
</div></MobileSheet>{/if}

<style>
  .aux-workspace { position:fixed; inset:var(--app-viewport-top,0px) 0 auto; height:var(--app-viewport-height,100dvh); overflow-y:auto; overscroll-behavior:contain; background:var(--color-bg); color:var(--color-text); padding:calc(20px + var(--app-control-safe-top,0px)) max(20px,calc((100vw - 620px)/2)) calc(32px + var(--app-control-safe-bottom,0px)); box-sizing:border-box; }
  .aux-header { display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:24px; }.aux-header>div:last-child {display:flex;} .aux-header span {display:flex;align-items:center;gap:7px;color:var(--color-muted);font-size:12px;font-weight:600;} h1{margin:6px 0 0;font-size:29px;letter-spacing:-.6px;overflow-wrap:anywhere;}
  .aux-icon {display:inline-flex;align-items:center;justify-content:center;border:0;background:transparent;color:var(--color-text);border-radius:12px;min-width:44px;min-height:44px;padding:8px;touch-action:manipulation;} button:disabled{opacity:.4;} .aux-status{display:flex;align-items:center;gap:12px;background:var(--color-panel);padding:14px;border-radius:14px;margin-bottom:16px;} .aux-status p{margin:0;font-size:14px;line-height:1.5;}.aux-notice{font-size:13px;color:var(--color-muted);}
  .aux-playing {max-width:380px;margin:0 auto 24px;} .aux-cover{width:min(100%,280px);aspect-ratio:1;border-radius:22px;overflow:hidden;margin:0 auto 22px;display:grid;place-items:center;background:var(--color-panel);} .aux-cover img{width:100%;height:100%;object-fit:cover;}.aux-song{display:flex;align-items:center;gap:12px;justify-content:space-between;}.aux-song h2{margin:0;font-size:21px;line-height:1.25;}.aux-song p{margin:5px 0 0;color:var(--color-muted);}.aux-progress{margin-top:16px;}.aux-progress progress{appearance:none;width:100%;height:4px;border:0;border-radius:2px;overflow:hidden;background:var(--color-surface);}.aux-progress progress::-webkit-progress-bar{background:var(--color-surface);}.aux-progress progress::-webkit-progress-value{background:var(--color-accent);}.aux-progress progress::-moz-progress-bar{background:var(--color-accent);}.aux-progress>span{display:flex;justify-content:space-between;margin-top:6px;font-size:12px;color:var(--color-muted);}
  .aux-transport{display:flex;justify-content:center;align-items:center;gap:32px;margin:14px 0;}.aux-play{width:64px;height:64px;display:grid;place-items:center;border:0;border-radius:50%;background:var(--color-accent);color:var(--button-primary-text);}.aux-listen,.aux-personal{display:flex;align-items:center;justify-content:center;gap:9px;padding:12px 16px;min-height:44px;font:inherit;border:1px solid var(--color-border);background:var(--color-panel);color:var(--color-text);border-radius:14px;width:100%;}.aux-speaker-note{text-align:center;font-size:13px;color:var(--color-muted);}.aux-empty-playing{padding:36px 16px;text-align:center;}.aux-empty-playing h2{font-size:20px;}
  .aux-tabs{display:flex;gap:8px;border-bottom:1px solid var(--color-border);margin-bottom:12px;}.aux-tabs button{flex:1;border:0;border-bottom:2px solid transparent;background:none;min-height:48px;font:inherit;font-weight:600;color:var(--color-muted);}.aux-tabs button[aria-current]{border-bottom-color:var(--color-accent);color:var(--color-text);}.aux-tabs span{font-size:12px;margin-left:4px;}.aux-empty{padding:16px;color:var(--color-muted);line-height:1.5;}
  .aux-row{display:flex;align-items:center;gap:10px;height:74px;box-sizing:border-box;background:var(--color-bg);border-bottom:1px solid var(--color-border);}.aux-thumb{width:48px;height:48px;border-radius:10px;background:var(--color-panel);overflow:hidden;flex-shrink:0;}.aux-thumb img{width:100%;height:100%;object-fit:cover;}.aux-row-copy{flex:1;min-width:0;display:grid;gap:5px;}.aux-row-copy strong,.aux-row-copy small{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}.aux-row-copy strong{font-size:15px;}.aux-row-copy small{font-size:12px;color:var(--color-muted);}.aux-grip{touch-action:none;color:var(--color-muted);}.aux-drop{outline:2px solid var(--color-accent);outline-offset:-2px;}.aux-remove{color:var(--color-muted);min-width:32px;width:32px;padding:4px;}
  .aux-catalog>input,.aux-management>input{width:100%;padding:14px;border:1px solid var(--color-border);background:var(--color-panel);color:var(--color-text);font:inherit;border-radius:12px;box-sizing:border-box;}.aux-personal{margin:12px 0;}.aux-management{padding:20px 24px 32px;display:grid;gap:16px;color:var(--color-text);}.aux-management p{font-size:13px;line-height:1.5;color:var(--color-muted);margin:0;}.aux-qr{width:220px;height:220px;max-width:100%;border-radius:18px;justify-self:center;}.aux-invite-actions{display:flex;flex-wrap:wrap;gap:10px;}.aux-member{display:flex;justify-content:space-between;align-items:center;min-height:48px;border-bottom:1px solid var(--color-border);}.aux-end{color:var(--color-danger);margin-top:20px;}
  @media(min-width:981px){.aux-workspace{padding-top:28px;}.aux-cover{width:220px;}}
</style>
