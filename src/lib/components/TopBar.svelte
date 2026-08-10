<script lang="ts">
  import { Search, X } from "lucide-svelte";

  let {
    searchQuery = $bindable()
  }: {
    searchQuery: string;
  } = $props();

  let searchInputEl: HTMLInputElement | undefined = $state();

  export function focusSearch() {
    searchInputEl?.focus();
  }
</script>

<header class="topbar">
  <label class="search-box" aria-label="Search library">
    <Search size={18} />
    <input
      bind:this={searchInputEl}
      bind:value={searchQuery}
      placeholder="Search"
      type="search"
    />
    {#if searchQuery}
      <button title="Clear search" aria-label="Clear search" type="button" onclick={() => (searchQuery = "")}>
        <X size={16} />
      </button>
    {/if}
  </label>
</header>
