<script lang="ts">
  import {
    AudioWaveform,
    Check,
    Disc3,
    Home,
    Library,
    ListMusic,
    Radio,
    Settings,
    Users
  } from "lucide-svelte";

  let {
    selectedView,
    guestMode = false,
    auxCode = "",
    onSelectView,
    onOpenSettings,
    onShowAux
  }: {
    selectedView: string;
    guestMode?: boolean;
    auxCode?: string;
    onSelectView: (view: string) => void;
    onOpenSettings: () => void;
    onShowAux: () => void;
  } = $props();

  const primaryViews = [
    { id: "home", label: "Home", icon: Home },
    { id: "all", label: "All Songs", icon: Library },
    { id: "liked", label: "Liked Songs", icon: Check },
    { id: "artists", label: "Artists", icon: Users },
    { id: "albums", label: "Albums", icon: Disc3 },
    { id: "playlists", label: "Playlists", icon: ListMusic },
    { id: "visualizer", label: "Visualizer", icon: AudioWaveform }
  ];
</script>

<aside class="sidebar" aria-label="Library navigation">
  <div class="sidebar-wordmark">code<span>c</span></div>

  <nav class="nav-stack" aria-label="Primary">
    {#each primaryViews as view (view.id)}
      <button
        aria-label={view.label}
        class:active={selectedView === view.id}
        title={view.label}
        type="button"
        onclick={() => onSelectView(view.id)}
      >
        <view.icon size={18} />
        <span>{view.label}</span>
      </button>
    {/each}
  </nav>

  <div class="sidebar-footer">
    {#if guestMode}
      <span class="sidebar-aux-chip" title="You're on the aux">
        <Radio size={14} />
        {auxCode}
      </span>
    {:else}
      {#if auxCode}
        <button class="sidebar-aux-chip live" title="Aux is live — show the QR" type="button" onclick={onShowAux}>
          <Radio size={14} />
          {auxCode}
        </button>
      {/if}
      <button class="sidebar-settings" title="Settings" aria-label="Settings" type="button" onclick={onOpenSettings}>
        <Settings size={17} />
      </button>
    {/if}
  </div>
</aside>
