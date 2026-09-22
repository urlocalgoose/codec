/** Session-only cover cache shared by lists, Now Playing, and color sampling.
 * Blob URLs keep remounts off the network; active consumers pin their entries.
 * Credentials never become persistent cache keys. */
export interface ArtworkLease {
  url: string | null;
  ready: Promise<string>;
  release(): void;
}
interface Entry {
  url: string | null;
  ready: Promise<string> | null;
  controller: AbortController;
  bytes: number;
  currentBytes: number;
  urlRefs: Map<string, number>;
  retired: Map<string, number>;
  refs: number;
  loadedAt: number;
}
interface Dependencies {
  fetch?: typeof fetch;
  createURL?: (blob: Blob) => string;
  revokeURL?: (url: string) => void;
  now?: () => number;
  maxEntries?: number;
  maxBytes?: number;
  maxAge?: number;
}

export function artworkCacheKey(src: string): string {
  try {
    const url = new URL(src, typeof document === 'undefined' ? undefined : document.baseURI);
    // Preserve version/signature parameters and arbitrary third-party tokens.
    if (/\/api\/v1\/(tracks|playlists)\/[^/]+\/artwork$/.test(url.pathname)) url.searchParams.delete('access_token');
    return url.href;
  } catch { return src; }
}

export function createArtworkCache(dependencies: Dependencies = {}) {
  const entries = new Map<string, Entry>();
  const now = dependencies.now ?? Date.now;
  const maxEntries = dependencies.maxEntries ?? 96;
  const maxBytes = dependencies.maxBytes ?? 24 * 1024 * 1024;
  const maxAge = dependencies.maxAge ?? 10 * 60_000;
  const revoke = dependencies.revokeURL ?? ((url: string) => URL.revokeObjectURL(url));
  let generation = 0;

  function prune() {
    let bytes = [...entries.values()].reduce((sum, entry) => sum + entry.bytes, 0);
    for (const [key, entry] of entries) {
      if (entries.size <= maxEntries && bytes <= maxBytes) break;
      if (entry.refs || entry.ready) continue;
      entries.delete(key);
      bytes -= entry.bytes;
      if (entry.url) revoke(entry.url);
      for (const url of entry.retired.keys()) revoke(url);
    }
  }

  function peek(src: string): string | null {
    return entries.get(artworkCacheKey(src))?.url ?? null;
  }

  function acquire(src: string): ArtworkLease {
    // Tauri's local asset protocol and already-local images need no fetch.
    if (/^(data:|blob:|asset:|tauri:)/.test(src)) return {url: src, ready: Promise.resolve(src), release() {}};
    const key = artworkCacheKey(src);
    let entry = entries.get(key);
    if (!entry) {
      entry = {url: null, ready: null, controller: new AbortController(), bytes: 0, currentBytes: 0, urlRefs: new Map(), retired: new Map(), refs: 0, loadedAt: 0};
    }
    entries.delete(key);
    entries.set(key, entry);
    entry.refs++;
    const current = entry;
    let heldURL = current.url;
    let released = false;
    const retain = (url: string) => current.urlRefs.set(url, (current.urlRefs.get(url) ?? 0) + 1);
    const releaseURL = (url: string) => {
      const count = Math.max(0, (current.urlRefs.get(url) ?? 0) - 1);
      current.urlRefs.set(url, count);
      if (!count && current.retired.has(url)) {
        current.bytes -= current.retired.get(url)!;
        current.retired.delete(url);
        current.urlRefs.delete(url);
        revoke(url);
      }
    };
    if (heldURL) retain(heldURL);
    if (!current.ready && (!current.url || now() - current.loadedAt >= maxAge)) {
      const requestGeneration = generation;
      current.controller = new AbortController();
      current.ready = (async () => {
        const response = await (dependencies.fetch ?? globalThis.fetch)(src, {signal: current.controller.signal});
        if (!response.ok || response.status === 206) throw new Error('Artwork unavailable');
        const blob = await response.blob();
        if (!blob.size || !blob.type.startsWith('image/') || blob.size > 8 * 1024 * 1024) throw new Error('Invalid artwork');
        if (requestGeneration !== generation || entries.get(key) !== current) throw new DOMException('Artwork connection changed', 'AbortError');
        const url = dependencies.createURL ? dependencies.createURL(blob) : URL.createObjectURL(blob);
        if (current.url) {
          if (current.urlRefs.get(current.url)) current.retired.set(current.url, current.currentBytes);
          else { revoke(current.url); current.bytes -= current.currentBytes; current.urlRefs.delete(current.url); }
        }
        current.url = url;
        current.currentBytes = blob.size;
        current.bytes += blob.size;
        current.loadedAt = now();
        return url;
      })().catch(error => {
        if (requestGeneration !== generation) throw new DOMException('Artwork connection changed', 'AbortError');
        throw error;
      }).finally(() => {
        current.ready = null;
        if (!current.url && entries.get(key) === current) entries.delete(key);
        prune();
      });
    }
    const ready = (current.ready ?? Promise.resolve(current.url!)).then(url => {
      if (!released && heldURL !== url) {
        if (heldURL) releaseURL(heldURL);
        heldURL = url;
        retain(url);
      }
      return url;
    });
    return {
      url: current.url,
      ready,
      release() {
        if (released) return;
        released = true;
        current.refs--;
        if (heldURL) releaseURL(heldURL);
        prune();
      }
    };
  }

  function clear() {
    generation++;
    for (const entry of entries.values()) {
      entry.controller.abort();
      if (entry.url) revoke(entry.url);
      for (const url of entry.retired.keys()) revoke(url);
      entry.retired.clear();
      entry.urlRefs.clear();
      entry.url = null;
      entry.bytes = entry.currentBytes = 0;
    }
    entries.clear();
  }
  return {acquire, peek, clear, get generation() { return generation; }};
}

export const artworkCache = createArtworkCache();
