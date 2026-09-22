<script lang="ts">
  import { X } from 'lucide-svelte';
  import { downloadStatus } from '$lib/download-status';
  function reserveSpace(node: HTMLElement) {
    const host = node.closest<HTMLElement>('.mobile-sheet-panel') ?? document.documentElement;
    let frame = 0;
    const measure = () => {
      frame = 0;
      // Include the gap between feedback and the controls beneath it.
      host.style.setProperty('--download-status-height', `${Math.ceil(node.getBoundingClientRect().height) + 8}px`);
    };
    const observer = new ResizeObserver(() => { if (!frame) frame = requestAnimationFrame(measure); });
    observer.observe(node, { box: 'border-box' });
    measure();
    return { destroy() { cancelAnimationFrame(frame); observer.disconnect(); host.style.removeProperty('--download-status-height'); } };
  }
</script>

{#if $downloadStatus}
  <aside use:reserveSpace class="download-status" data-state={$downloadStatus.state} aria-label="Downloads">
    <div class="download-status-copy" role="status" aria-live="polite">
      <strong>{$downloadStatus.message}</strong>
      {#if $downloadStatus.detail}<small>{$downloadStatus.detail}</small>{/if}
    </div>
    {#if $downloadStatus.progress !== undefined}
      <progress max="1" value={$downloadStatus.progress} aria-label="Download progress"></progress>
    {/if}
    <button type="button" aria-label={$downloadStatus.cancel ? 'Cancel downloads' : 'Dismiss download status'}
      onclick={() => { if ($downloadStatus?.cancel) $downloadStatus.cancel(); else downloadStatus.set(null); }}><X size={18}/></button>
  </aside>
{/if}
