<script lang="ts">
  import { onMount } from "svelte";
  import { version } from "$app/environment";
  import { ArrowLeft, ExternalLink, Radio } from "lucide-svelte";
  import { auxRequest, type AuxInvitation, type AuxInviteInfo, type AuxJoined, type AuxConnection } from "$lib/aux-v2";
  let { invitation, onJoin, onCancel }: { invitation: AuxInvitation; onJoin: (connection: AuxConnection, state: AuxJoined["state"]) => void; onCancel: () => void } = $props();
  let info = $state<AuxInviteInfo | null>(null);
  let name = $state(""); let error = $state(""); let busy = $state(false);
  const controller = new AbortController();
  onMount(() => {
    auxRequest<AuxInviteInfo>(invitation.server, "/api/v2/aux/invitation", "", { invite_secret: invitation.secret }, undefined, controller.signal)
      .then(value => info = value).catch(reason => { if (!controller.signal.aborted) error = reason instanceof Error ? reason.message : String(reason); });
    return () => controller.abort();
  });
  async function join() {
    if (!info || busy) return;
    busy = true; error = "";
    try {
      const result = await auxRequest<AuxJoined>(invitation.server, "/api/v2/aux/join", "", { invite_secret: invitation.secret, display_name: name.trim() || "Guest" }, undefined, controller.signal);
      if (controller.signal.aborted) return;
      onJoin({ server:invitation.server, session_id:result.session_id, participant_id:result.participant_id, token:result.participant_token, expires_at:result.expires_at, role:"guest" }, result.state);
    } catch (reason) { error = reason instanceof Error ? reason.message : String(reason); }
    finally { busy = false; }
  }
  const appLink = $derived(`${version.startsWith("local-") ? "codec-test" : "codec"}://aux-v2?server=${encodeURIComponent(invitation.server)}&invite=${encodeURIComponent(invitation.secret)}`);
</script>
<section class="aux-join" aria-labelledby="join-title">
  <button class="aux-back" type="button" onclick={onCancel} disabled={busy}><ArrowLeft size={20}/>Back</button>
  <div class="aux-join-card">
    <Radio size={32}/><h1 id="join-title">Join Aux</h1>
    {#if info}<h2>{info.host_name || "Codec"}</h2><p>{info.mode === "listen_together" ? "Listen together on your own devices." : "Control music playing on the host’s speaker."}</p>
      <p class="aux-join-permissions">You can pause, resume, skip, add songs, remove your requests, and reorder the upcoming queue.</p>
      <form onsubmit={(event) => { event.preventDefault(); void join(); }}>
        <label>Your name<input bind:value={name} maxlength="40" placeholder="Guest" autocomplete="nickname"/></label>
        <button class="ui-button primary" disabled={busy}>{busy ? "Joining…" : "Join in this browser"}</button>
      </form>
      <a class="aux-app-link" href={appLink}>Open in Codec <ExternalLink size={16}/></a><small>Requires an updated Codec app. You can also join here without installing it.</small>
    {:else if !error}<p>Checking invitation…</p>{/if}
    {#if error}<p class="aux-error" role="alert">{error}</p>{/if}
    <p class="aux-server">{new URL(invitation.server).host}</p>
  </div>
</section>

<style>
  .aux-join { position:fixed; inset:var(--app-viewport-top,0px) 0 auto; height:var(--app-viewport-height,100dvh); box-sizing:border-box; padding:calc(20px + var(--app-control-safe-top,0px)) 24px calc(24px + var(--app-control-safe-bottom,0px)); background:var(--color-bg); color:var(--color-text); overflow-y:auto; }
  .aux-join-card { max-width:420px; margin:40px auto; display:grid; gap:16px; }
  h1 { font-size:32px; margin:0; } h2 { font-size:21px; margin:0; }
  p { margin:0; line-height:1.5; } .aux-join-permissions,small,.aux-server { color:var(--color-muted); }
  form,label { display:grid; gap:10px; } form { gap:20px; } input { background:var(--color-panel); color:var(--color-text); border:1px solid var(--color-border); border-radius:14px; padding:16px; font:inherit; width:100%; box-sizing:border-box; }
  .aux-back,.aux-app-link { display:inline-flex; align-items:center; gap:8px; min-height:44px; background:none; border:0; color:var(--color-accent); font:inherit; text-decoration:none; }
  .aux-error { color:var(--color-danger); } .aux-server { font-size:13px; overflow-wrap:anywhere; }
</style>
