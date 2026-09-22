<script lang="ts" generics="T">
  import { onMount, tick, type Snippet } from "svelte";

  let { items, rowHeight = 62, children }: {
    items: T[];
    rowHeight?: number;
    children: Snippet<[T, number]>;
  } = $props();
  let container: HTMLDivElement;
  let first = $state(0);
  let last = $state(24);
  let schedule = () => {};
  const rows = $derived(items.slice(first, last));

  // Keyboard users can reach a row outside the currently mounted window.
  // Render only its neighborhood before focusing; normal focus scrolling then
  // brings the parent viewport and the scheduled virtual window into step.
  export async function focusRow(index: number, selector: string) {
    if (index < 0 || index >= items.length) return;
    if (index < first || index >= last) {
      first = Math.max(0, index - 6);
      last = Math.min(items.length, index + 7);
      await tick();
    }
    container.querySelector<HTMLElement>(`[data-virtual-index="${index}"] ${selector}`)?.focus();
  }

  // The wrapper always exists, including when the list starts empty, so
  // observers bind to its real scrolling parent before any rows appear.
  onMount(() => {
    let parent = container.parentElement;
    while (parent && !/(auto|scroll)/.test(getComputedStyle(parent).overflowY)) {
      parent = parent.parentElement;
    }
    const scroller = parent;
    const target = scroller ?? window;
    let frame = 0;
    function update() {
      frame = 0;
      const bounds = container.getBoundingClientRect();
      const viewport = scroller?.getBoundingClientRect();
      const top = viewport?.top ?? 0;
      const bottom = viewport?.bottom ?? window.innerHeight;
      first = Math.min(items.length, Math.max(0, Math.floor((top - bounds.top) / rowHeight) - 6));
      last = Math.min(items.length, Math.max(first, Math.ceil((bottom - bounds.top) / rowHeight) + 6));
    }
    schedule = () => { if (!frame) frame = requestAnimationFrame(update); };
    const observer = new ResizeObserver(schedule);
    observer.observe(container);
    if (scroller) observer.observe(scroller);
    target.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    update();
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      target.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      schedule = () => {};
    };
  });

  $effect(() => { items; rowHeight; schedule(); });
</script>

<div class="virtual-rows" bind:this={container} style:height={`${items.length * rowHeight}px`}>
  <div class="virtual-rows-slice" style:transform={`translateY(${first * rowHeight}px)`}>
    {#each rows as item, index (first + index)}
      <div class="virtual-row" data-virtual-index={first + index} style:height={`${rowHeight}px`}>
        {@render children(item, first + index)}
      </div>
    {/each}
  </div>
</div>

<style>
  .virtual-rows { position: relative; }
  .virtual-rows-slice { position: absolute; inset: 0 0 auto; }
  .virtual-row { overflow: hidden; }
</style>
