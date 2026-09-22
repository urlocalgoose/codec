<script lang="ts">
  import type { HTMLImgAttributes } from 'svelte/elements';
  import { artworkCache } from '$lib/artwork-cache';

  let { src, alt = '', loading = 'eager', ...attributes }: Omit<HTMLImgAttributes, 'src'> & {src?: string | null} = $props();
  let image = $state<HTMLImageElement>();
  let displayed = $state<string | undefined>();

  $effect(() => {
    const url = src;
    const node = image;
    if (!url || !node) { displayed = undefined; return; }
    let cancelled = false;
    let release: (() => void) | undefined;
    let observer: IntersectionObserver | undefined;
    const cached = artworkCache.peek(url);
    displayed = cached ?? undefined;
    const load = () => {
      observer?.disconnect();
      const lease = artworkCache.acquire(url);
      release = lease.release;
      displayed = lease.url ?? undefined;
      void lease.ready.then(value => { if (!cancelled) displayed = value; }, (error: unknown) => {
        // Hosts without fetch CORS may still allow a normal image to display.
        if (!cancelled) displayed = error instanceof Error && error.name === "AbortError" ? undefined : url;
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

<img {...attributes} bind:this={image} src={displayed} {alt} decoding="async" />
