<script lang="ts">
  import { untrack } from 'svelte';
  import type { HTMLImgAttributes } from 'svelte/elements';
  import { artworkCache } from '$lib/artwork-cache';

  let { src, alt = '', loading = 'eager', class: className = '', style, onload, onerror, ...attributes }: Omit<HTMLImgAttributes, 'src'> & {src?: string | null} = $props();
  let surface = $state<HTMLSpanElement>();
  let image = $state<HTMLImageElement>();
  let displayed = $state<string | undefined>(untrack(() => src ? artworkCache.peek(src) ?? undefined : undefined));
  let status = $state<'loading' | 'ready' | 'error'>('loading');
  let fade = $state(false);

  function loaded(event: Event & { currentTarget: EventTarget & Element }) {
    const node = event.currentTarget;
    if (!(node instanceof HTMLImageElement) || node.getAttribute('src') !== displayed || !node.complete || !node.naturalWidth) return;
    status = 'ready';
    onload?.(event);
  }

  function failed(event: Event & { currentTarget: EventTarget & Element }) {
    if (event.currentTarget.getAttribute('src') !== displayed) return;
    status = 'error';
    onerror?.(event);
  }

  $effect(() => {
    const node = image;
    // Cached images can already be decoded before their load event is delivered.
    if (node?.complete && node.naturalWidth && node.getAttribute('src') === displayed) status = 'ready';
  });

  $effect(() => {
    const url = src;
    const node = surface;
    if (!url || !node) { displayed = undefined; status = 'loading'; return; }
    let cancelled = false;
    let release: (() => void) | undefined;
    let observer: IntersectionObserver | undefined;
    const cached = artworkCache.peek(url);
    // A rotated stream token can still resolve to the same decoded blob.
    // Preserve its loaded state: assigning the same src fires no new load event.
    status = untrack(() => cached && cached === displayed ? status : 'loading');
    fade = !cached;
    displayed = cached ?? undefined;
    const load = () => {
      observer?.disconnect();
      const lease = artworkCache.acquire(url);
      release = lease.release;
      displayed = lease.url ?? undefined;
      void lease.ready.then(value => {
        if (!cancelled) {
          if (displayed !== value) status = 'loading';
          displayed = value;
        }
      }, (error: unknown) => {
        if (cancelled) return;
        if (error instanceof Error && error.name === 'AbortError') {
          displayed = undefined;
          status = 'loading';
        } else if (status !== 'ready') {
          // Hosts without fetch CORS may still allow a normal image to display.
          // Hide it until loaded, or retain a good cached cover if refresh failed.
          status = 'loading';
          displayed = url;
        }
      });
    };
    if (cached || loading !== 'lazy' || typeof IntersectionObserver === 'undefined') load();
    else {
      observer = new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) load(); }, {rootMargin: '240px'});
      observer.observe(node);
    }
    return () => { cancelled = true; observer?.disconnect(); release?.(); };
  });
</script>

<span class={['artwork-image', className]} {style} data-artwork-state={status} class:fade bind:this={surface}>
  <svg class="artwork-image-placeholder" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M9 18V5l12-2v13M9 9l12-2" />
    <ellipse cx="6" cy="18" rx="3" ry="3" /><ellipse cx="18" cy="16" rx="3" ry="3" />
  </svg>
  {#key displayed}
    {#if displayed}
      <img {...attributes} bind:this={image} src={displayed} {alt} decoding="async" onload={loaded} onerror={failed} />
    {/if}
  {/key}
</span>

<style>
  .artwork-image {
    position: relative;
    display: inline-block;
    overflow: hidden;
    vertical-align: middle;
    background: var(--color-panel-2);
    aspect-ratio: 1;
  }
  .artwork-image-placeholder {
    position: absolute;
    left: 50%;
    top: 50%;
    width: 36%;
    height: 36%;
    max-width: 72px;
    max-height: 72px;
    transform: translate(-50%, -50%);
    color: var(--color-subtle);
    opacity: .45;
    pointer-events: none;
  }
  .artwork-image > img {
    position: absolute;
    inset: 0;
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    visibility: hidden;
    opacity: 0;
  }
  .artwork-image[data-artwork-state='ready'] > img {
    visibility: visible;
    opacity: 1;
  }
  .artwork-image[data-artwork-state='ready'] > .artwork-image-placeholder { visibility: hidden; }
  @media (prefers-reduced-motion: no-preference) {
    .artwork-image.fade > img { transition: opacity 120ms ease-out; }
  }
</style>
