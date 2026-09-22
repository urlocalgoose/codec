<script lang="ts">
  import { onMount } from "svelte";
  let { selected, onSelect }: { selected: string; onSelect: (view: string) => void } = $props();
  let navigation: HTMLElement;
  const tabs = [
    { id: "home", label: "Home" }, { id: "search", label: "Search" },
    { id: "library", label: "Library" }, { id: "visualizer", label: "Visualizer" }
  ];

  onMount(() => {
    const controls = navigation.closest<HTMLElement>(".mobile-bottom-controls");
    const shell = navigation.closest<HTMLElement>(".app-shell");
    if (!controls || !shell) return;
    const root = document.documentElement;
    let frame = 0;
    const update = () => {
      frame = 0;
      const height = `${Math.ceil(controls.getBoundingClientRect().height)}px`;
      if (shell.style.getPropertyValue("--mobile-controls-height") !== height) {
        shell.style.setProperty("--mobile-controls-height", height);
        root.style.setProperty("--mobile-controls-height", height);
      }
    };
    // The mini player and any status feedback can change independently of the
    // current tab. Reserve their actual total height for the last content row.
    const observer = new ResizeObserver(() => { if (!frame) frame = requestAnimationFrame(update); });
    observer.observe(controls, { box: "border-box" });
    update();
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      shell.style.removeProperty("--mobile-controls-height");
      root.style.removeProperty("--mobile-controls-height");
    };
  });
</script>

<nav bind:this={navigation} class="mobile-tab-bar" aria-label="Mobile navigation" style={`--selected-tab:${Math.max(0, tabs.findIndex(tab => tab.id === selected))}`}>
  <i class="mobile-tab-selection" aria-hidden="true"></i>
  {#each tabs as tab (tab.id)}
    <button type="button" class:active={selected === tab.id} aria-current={selected === tab.id ? "page" : undefined} onclick={() => onSelect(tab.id)}>
      <svg width="28" height="28" viewBox="0 0 28 28" fill="none" aria-hidden="true">
        {#if tab.id === "home"}
          <path d="M2 12.5 14 2.5 26 12.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
          <path d="M5 11.5 14 4 23 11.5v13a1.5 1.5 0 0 1-1.5 1.5H6.5A1.5 1.5 0 0 1 5 24.5Z M11 17h6v9h-6Z" fill="currentColor" fill-rule="evenodd"/>
        {:else if tab.id === "search"}
          <circle cx="12" cy="11.5" r="8.5" stroke="currentColor" stroke-width="2.4"/><path d="m18.5 18 7 7" stroke="currentColor" stroke-width="2.8" stroke-linecap="round"/>
        {:else if tab.id === "library"}
          <rect x="4" y="7" width="20" height="20" rx="3" fill="currentColor"/><path d="M6 4.5h16M8 1.5h12" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>
        {:else}
          <path d="M3 11v6M7.5 5v18M12 1v26M16.5 7v14M21 4v20M25.5 11v6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>
        {/if}
      </svg>
      <span>{tab.label}</span>
    </button>
  {/each}
</nav>
