<script lang="ts">
  let { name, size = 24 }: {
    name: "play" | "pause" | "speaker-low" | "speaker-high" | "airplay" | "settings";
    size?: number;
  } = $props();
</script>

<svg class="mobile-symbol" width={size} height={size} viewBox="0 0 24 24" fill="none" aria-hidden="true">
  {#if name === "play"}
    <path d="M5.8 2.6c-.9-.55-1.8-.04-1.8 1.02v16.76c0 1.06.9 1.57 1.8 1.02l14-8.38c.85-.51.85-1.53 0-2.04Z" fill="currentColor"/>
  {:else if name === "pause"}
    <rect x="4" y="2" width="6" height="20" rx="1.4" fill="currentColor"/>
    <rect x="14" y="2" width="6" height="20" rx="1.4" fill="currentColor"/>
  {:else if name === "speaker-low" || name === "speaker-high"}
    <path d="M2 8.5h3L10 4c.6-.5 1-.25 1 .5v15c0 .75-.4 1-1 .5l-5-4.5H2c-.6 0-1-.4-1-1v-5c0-.6.4-1 1-1Z" fill="currentColor"/>
    {#if name === "speaker-high"}
      <path d="M14 9a4.2 4.2 0 0 1 0 6m3-9a8.3 8.3 0 0 1 0 12m3-15a12.5 12.5 0 0 1 0 18" stroke="currentColor" stroke-width="1.65" stroke-linecap="round"/>
    {/if}
  {:else if name === "airplay"}
    <path d="m7.2 22 4.3-6a.6.6 0 0 1 1 0l4.3 6Z" fill="currentColor"/>
    <path d="M5.4 18.3a9 9 0 1 1 13.2 0M7.4 15.9a6 6 0 1 1 9.2 0M9.5 13.6a3 3 0 1 1 5 0" stroke="currentColor" stroke-width="1.65" stroke-linecap="round"/>
  {:else}
    <g stroke="currentColor" stroke-width="1.7">
      <circle cx="12" cy="12" r="7.5"/><circle cx="12" cy="12" r="3"/>
      {#each Array.from({length: 10}, (_, i) => i) as tooth}
        <path d="M11.1 4.5V2.2h1.8v2.3" transform={`rotate(${tooth * 36} 12 12)`} stroke-linejoin="round"/>
      {/each}
    </g>
  {/if}
</svg>
