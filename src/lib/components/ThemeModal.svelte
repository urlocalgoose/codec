<script lang="ts">
  import { Check, X } from "lucide-svelte";
  import { themes, type ThemeId } from "$lib/themes";

  let {
    theme,
    activeThemeName,
    onSetTheme,
    onClose
  }: {
    theme: ThemeId;
    activeThemeName: string;
    onSetTheme: (theme: ThemeId) => void;
    onClose: () => void;
  } = $props();

  function handleBackdropClick(event: MouseEvent) {
    if (event.target === event.currentTarget) {
      onClose();
    }
  }
</script>

<div
  class="modal-backdrop"
  role="presentation"
  onclick={handleBackdropClick}
>
  <div
    class="app-modal theme-modal"
    role="dialog"
    aria-label="Choose theme"
    aria-modal="true"
  >
    <header class="modal-header">
      <div>
        <span>Theme</span>
        <h2>Choose Theme</h2>
        <p>{activeThemeName}</p>
      </div>
      <button
        class="title-icon-button"
        title="Close"
        aria-label="Close theme picker"
        type="button"
        onclick={onClose}
      >
        <X size={18} />
      </button>
    </header>

    <div class="theme-grid">
      {#each themes as option (option.id)}
        <button
          class="theme-choice"
          class:active={theme === option.id}
          type="button"
          aria-pressed={theme === option.id}
          onclick={() => onSetTheme(option.id)}
        >
          <span
            class="theme-swatch"
            style={`--a:${option.swatch[0]}; --b:${option.swatch[1]}; --c:${option.swatch[2]};`}
          ></span>
          <span>{option.name}</span>
          {#if theme === option.id}
            <Check size={16} />
          {/if}
        </button>
      {/each}
    </div>

    <footer class="modal-actions">
      <button class="ui-button primary compact" type="button" onclick={onClose}>
        Done
      </button>
    </footer>
  </div>
</div>
