<script lang="ts">
  import { tick, untrack } from "svelte";
  import { AlertCircle, ArrowLeft, ArrowUpRight, ChevronRight, CircleHelp, CloudDownload, FolderOpen, KeyRound, LoaderCircle, Link, Music2, Server } from "lucide-svelte";
  import type { ThemeId } from "$lib/themes";

  let {
    theme,
    isNative,
    loading,
    errorMessage,
    syncServerDraft = $bindable(),
    syncTokenDraft = $bindable(),
    onChooseFolder,
    onConnect
  }: {
    theme: ThemeId;
    isNative: boolean;
    loading: boolean;
    errorMessage: string;
    syncServerDraft: string;
    syncTokenDraft: string;
    onChooseFolder: () => void;
    onConnect: () => void;
  } = $props();

  type Step = "welcome" | "connect" | "setup" | "about";
  let step = $state<Step>(untrack(() => syncTokenDraft || errorMessage || loading ? "connect" : "welcome"));
  let heading = $state<HTMLHeadingElement>();

  async function goTo(next: Step) {
    if (loading) return;
    step = next;
    await tick();
    heading?.focus({ preventScroll: true });
    heading?.closest("main")?.scrollTo({ top: 0, behavior: "instant" });
  }
</script>

<main class="setup-screen" class:native-connect={!isNative} data-theme={theme}>
{#if !isNative}
  <section class="native-connect-form" aria-labelledby="onboarding-title">
    <div class="native-connect-brand"><img src="/favicon.png" alt=""/><strong>Codec</strong></div>
    {#key step}
      <div class="onboarding-page">
        {#if step !== "welcome"}
          <button class="onboarding-back" type="button" onclick={() => goTo("welcome")} disabled={loading} aria-label="Back to welcome"><ArrowLeft size={18} aria-hidden="true"/>Back to welcome</button>
        {/if}

        {#if step === "welcome"}
          <div class="native-connect-copy"><h1 id="onboarding-title" bind:this={heading} tabindex="-1">Welcome</h1><p>Codec plays music from a server you host.</p></div>
          <div class="onboarding-choices">
            <button type="button" class="onboarding-choice" aria-label="I have a server" onclick={() => goTo("connect")}><Server size={22} aria-hidden="true"/><span><strong>I have a server</strong><small>Connect to your music.</small></span><ChevronRight size={19} aria-hidden="true"/></button>
            <button type="button" class="onboarding-choice" aria-label="I need to set one up" onclick={() => goTo("setup")}><CloudDownload size={22} aria-hidden="true"/><span><strong>I need to set one up</strong><small>Start with the setup guide.</small></span><ChevronRight size={19} aria-hidden="true"/></button>
            <button type="button" class="onboarding-choice" aria-label="I'm confused" onclick={() => goTo("about")}><CircleHelp size={22} aria-hidden="true"/><span><strong>I'm confused</strong><small>See how Codec works.</small></span><ChevronRight size={19} aria-hidden="true"/></button>
          </div>
        {:else if step === "connect"}
          <div class="native-connect-copy"><h1 id="onboarding-title" bind:this={heading} tabindex="-1">Connect to your library</h1><p>Enter your server address and auth token.</p></div>
          <form class="onboarding-connect" onsubmit={(event) => { event.preventDefault(); if (!loading && syncServerDraft.trim()) onConnect(); }}>
            <div class="native-connect-fields">
              <label>Server address<span><Link size={20} aria-hidden="true"/><input bind:value={syncServerDraft} type="url" placeholder="https://music.example.com" aria-label="Server address" autocapitalize="none" spellcheck="false" disabled={loading}/></span></label>
              <label>Auth token<span><KeyRound size={20} aria-hidden="true"/><input bind:value={syncTokenDraft} type="password" placeholder="Paste your token" aria-label="Auth token" autocomplete="off" autocapitalize="none" spellcheck="false" disabled={loading}/></span></label>
            </div>
            <div class="native-connect-submit">
              {#if errorMessage}<p class="setup-error" role="alert"><AlertCircle size={17} aria-hidden="true"/>{errorMessage}</p>{/if}
              <button type="submit" disabled={loading || !syncServerDraft.trim()}>{#if loading}<LoaderCircle size={18} class="spin-icon" aria-hidden="true"/>{/if}{loading ? "Connecting…" : "Connect"}</button>
              <p>Use the same server and token as your other devices.</p>
            </div>
          </form>
        {:else if step === "setup"}
          <div class="native-connect-copy"><h1 id="onboarding-title" bind:this={heading} tabindex="-1">Set up a server</h1><p>Your server stores your music and makes it available to Codec.</p></div>
          <p class="onboarding-explanation">Run it on a computer you keep on, or on a cloud server. The setup guide covers installation and adding your music.</p>
          <div class="onboarding-actions">
            <a class="onboarding-primary" href="https://codec.codie.sh/docs/hosting.html" target="_blank" rel="noopener noreferrer">Open setup guide<ArrowUpRight size={18} aria-hidden="true"/></a>
            <button class="onboarding-secondary" type="button" onclick={() => goTo("connect")}>I have my server details<ChevronRight size={18} aria-hidden="true"/></button>
          </div>
        {:else}
          <div class="native-connect-copy"><h1 id="onboarding-title" bind:this={heading} tabindex="-1">How Codec works</h1><p>Codec is an open-source, self-hosted music player.</p></div>
          <div class="onboarding-explanation">
            <section class="onboarding-topic" aria-labelledby="onboarding-meaning"><h2 id="onboarding-meaning">What that means</h2><p>The code is public, so you can read it, change it, and run it yourself. Your library lives on a server you control, at home or in the cloud.</p></section>
            <section class="onboarding-topic" aria-labelledby="onboarding-why"><h2 id="onboarding-why">Why self-host</h2><p>Keep your music in one place and listen across your devices, with control over your files and who can access them.</p></section>
            <section class="onboarding-topic" aria-labelledby="onboarding-start"><h2 id="onboarding-start">Get started</h2><p>Install the Codec server on Linux, add your music, then connect the app or web player with the server address and auth token.</p></section>
          </div>
          <div class="onboarding-actions">
            <a class="onboarding-primary" href="https://codec.codie.sh/docs/hosting.html" target="_blank" rel="noopener noreferrer">Open setup guide<ArrowUpRight size={18} aria-hidden="true"/></a>
            <button class="onboarding-secondary" type="button" onclick={() => goTo("connect")}>I have a server<ChevronRight size={18} aria-hidden="true"/></button>
            <a class="onboarding-site" href="https://codec.codie.sh/" target="_blank" rel="noopener noreferrer">Visit the Codec website<ArrowUpRight size={16} aria-hidden="true"/></a>
          </div>
        {/if}
      </div>
    {/key}
    <footer class="onboarding-footer"><a href="https://codec.codie.sh/privacy.html" target="_blank" rel="noopener noreferrer">Privacy Policy</a><a href="https://codec.codie.sh/support.html" target="_blank" rel="noopener noreferrer">Support</a></footer>
  </section>
{:else}
  <section class="setup-panel" aria-labelledby="setup-title">
    <div class="brand-row">
      <span class="brand-mark"><Music2 size={32} /></span>
      <span>Codec</span>
    </div>
    <span class="setup-mode">Desktop</span>
    <h1 id="setup-title">Local music, folder-first.</h1>
    <p>
      Pick a music folder, or connect to a Codec sync server to push and pull real MP3 files.
    </p>
    <div class="setup-actions">
      <button class="primary-action" type="button" onclick={onChooseFolder}>
        <FolderOpen size={18} />
        Open Music Folder
      </button>
    </div>
    <div class="setup-sync-card">
      <div class="setup-sync-copy">
        <strong>Sync Server</strong>
        <span>Use this desktop as a client or uploader.</span>
      </div>
      <div class="setup-sync">
        <label class="sync-url-field">
          <Server size={17} />
          <input
            bind:value={syncServerDraft}
            placeholder="https://your-server or 192.168.1.20:8787"
            type="url"
          />
        </label>
        <label class="sync-url-field">
          <KeyRound size={17} />
          <input
            bind:value={syncTokenDraft}
            placeholder="Auth token"
            type="password"
            autocomplete="off"
          />
        </label>
        <button class="primary-action" disabled={loading || !syncServerDraft.trim()} type="button" onclick={onConnect}>
          {#if loading}
            <LoaderCircle class="spin-icon" size={18} />
          {:else}
            <CloudDownload size={18} />
          {/if}
          Connect
        </button>
      </div>
    </div>
    {#if errorMessage}
      <p class="setup-error"><AlertCircle size={16} /> {errorMessage}</p>
    {/if}
  </section>
{/if}
</main>

<style>
  .onboarding-page, .onboarding-connect { display:grid; grid-template-columns:minmax(0,1fr); gap:28px; min-width:0; }
  .native-connect-fields, .native-connect-fields label, .native-connect-fields label>span { min-width:0; }
  .onboarding-page { animation:onboarding-enter 180ms ease-out both; }
  .onboarding-page h1:focus { outline:none; }
  .onboarding-back { display:inline-flex; justify-self:start; align-items:center; gap:8px; min-height:44px; margin:-12px 0; padding:0 8px 0 0; background:none; border:0; color:var(--color-muted); font-size:15px; font-weight:600; }
  .onboarding-choices { display:grid; gap:10px; }
  .onboarding-choice { display:flex; align-items:center; gap:14px; padding:16px; min-height:78px; width:100%; text-align:left; border:1px solid var(--color-border); border-radius:14px; background:var(--color-panel); color:var(--color-text); }
  .onboarding-choice>span { display:grid; gap:5px; flex:1; min-width:0; }
  .onboarding-choice strong { font-size:17px; line-height:1.25; font-weight:600; }
  .onboarding-choice small { font-size:14px; line-height:1.35; color:var(--color-muted); }
  .onboarding-choice :global(svg) { flex-shrink:0; color:var(--color-muted); }
  .onboarding-choice:hover { background:var(--color-surface); }
  .onboarding-actions { display:grid; gap:10px; }
  .onboarding-primary, .onboarding-secondary { display:flex; justify-content:center; align-items:center; gap:10px; padding:15px 16px; min-height:54px; border-radius:14px; border:0; text-align:center; font-size:17px; font-weight:600; line-height:1.4; text-decoration:none; }
  .onboarding-primary { background:var(--color-accent); color:var(--button-primary-text); }
  .onboarding-secondary { background:var(--color-panel); border:1px solid var(--color-border); color:var(--color-text); }
  .onboarding-primary :global(svg), .onboarding-secondary :global(svg) { flex-shrink:0; }
  .onboarding-explanation { margin:0; display:grid; gap:18px; font-size:17px; line-height:1.5; color:var(--color-muted); }
  .onboarding-explanation p { margin:0; }
  .onboarding-topic { display:grid; gap:8px; }
  .onboarding-topic h2 { margin:0; color:var(--color-text); font-size:17px; line-height:1.4; font-weight:600; }
  .onboarding-site { display:inline-flex; justify-self:center; align-items:center; gap:6px; min-height:44px; color:var(--color-accent); font-size:14px; text-underline-offset:4px; }
  .onboarding-footer { display:flex; flex-wrap:wrap; gap:4px 24px; }
  .onboarding-footer a { display:inline-flex; align-items:center; min-height:44px; color:var(--color-muted); font-size:13px; text-underline-offset:4px; }
  .onboarding-choice, .onboarding-primary, .onboarding-secondary { transition:background-color 140ms ease, transform 140ms ease; touch-action:manipulation; }
  .onboarding-choice:active, .onboarding-primary:active, .onboarding-secondary:active { transform:scale(.985); }
  @keyframes onboarding-enter { from { opacity:0; transform:translateY(5px); } to { opacity:1; transform:translateY(0); } }
  @media (prefers-reduced-motion:reduce) { .onboarding-page { animation:none; } .onboarding-choice, .onboarding-primary, .onboarding-secondary { transition:none; transform:none; } }
</style>
