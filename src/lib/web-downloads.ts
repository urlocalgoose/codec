/** Browser audio downloads. Stream URLs (which may contain tokens) never enter cache keys. */
const CACHE_NAME = 'codec-audio-downloads-v1';
const KEY_ROOT = 'https://codec-download.invalid/v1/';

export interface AudioDownloadCache {
  match(key: string): Promise<Response | undefined>;
  put(key: string, response: Response): Promise<void>;
  delete(key: string): Promise<boolean>;
  keys(): Promise<readonly Request[]>;
}

export interface WebDownloadDependencies {
  openCache?: () => Promise<AudioDownloadCache>;
  fetch?: (url: string, options?: RequestInit) => Promise<Response>;
  createObjectURL?: (blob: Blob) => string;
}

export interface WebDownloads {
  listDownloaded(server: string): Promise<Set<string>>;
  downloadTrack(server: string, fingerprint: string, url: string): Promise<void>;
  downloadedTrackURL(server: string, fingerprint: string): Promise<string | null>;
  removeDownload(server: string, fingerprint: string): Promise<void>;
}

function serverPrefix(server: string): string {
  let value: URL;
  try { value = new URL(server); }
  catch { throw new Error('A valid server address is required for downloads.'); }
  if (value.protocol !== 'http:' && value.protocol !== 'https:') {
    throw new Error('A valid server address is required for downloads.');
  }
  value.username = '';
  value.password = '';
  value.search = '';
  value.hash = '';
  value.pathname = value.pathname.replace(/\/+$/, '');
  return `${KEY_ROOT}${encodeURIComponent(value.toString().replace(/\/$/, ''))}/`;
}

function trackKey(server: string, fingerprint: string): string {
  if (!fingerprint.trim()) throw new Error('This track has no download identifier.');
  return serverPrefix(server) + encodeURIComponent(fingerprint.trim());
}

function storageError(error: unknown): Error {
  if (error instanceof Error && error.name === 'QuotaExceededError') {
    return new Error('Not enough browser storage. Remove some downloads and try again.');
  }
  return new Error('Offline downloads are unavailable in this browser.');
}

async function audioBlob(response: Response): Promise<Blob> {
  if (response.status !== 200 || response.headers.has('content-range')) {
    throw new Error(response.status === 206 || response.headers.has('content-range')
      ? 'The server returned only part of this track. Please try again.'
      : `Could not download this track (HTTP ${response.status}).`);
  }
  const blob = await response.blob();
  if (!blob.size) throw new Error('The server returned an empty audio file.');
  const length = response.headers.get('content-length');
  if (length && /^\d+$/.test(length) && !response.headers.has('content-encoding') && Number(length) !== blob.size) {
    throw new Error('The audio download was incomplete. Please try again.');
  }
  const bytes = new Uint8Array(await blob.slice(0, 512).arrayBuffer());
  const text = new TextDecoder().decode(bytes);
  if (/^\s*(?:<|\{|\[)/.test(text)) {
    throw new Error('The server returned a page or error instead of audio.');
  }
  const mime = (response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
  const audioType = mime.startsWith('audio/') && !mime.includes('mpegurl');
  const signature = text.startsWith('ID3') || text.startsWith('fLaC') || text.startsWith('OggS')
    || (text.startsWith('RIFF') && text.slice(8, 12) === 'WAVE')
    || (text.startsWith('FORM') && ['AIFF', 'AIFC'].includes(text.slice(8, 12)))
    || text.slice(4, 8) === 'ftyp'
    || (bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0)
    || (bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3);
  const genericType = !mime || ['application/octet-stream', 'binary/octet-stream', 'application/ogg', 'video/mp4', 'video/webm'].includes(mime);
  if (!audioType && !(genericType && signature)) {
    throw new Error('The server did not return a supported audio file.');
  }
  return blob;
}

/** Dependencies make the browser storage behavior testable without network or a DOM. */
export function createWebDownloads(dependencies: WebDownloadDependencies = {}): WebDownloads {
  const versions = new Map<string, number>();
  const downloads = new Map<string, { version: number; promise: Promise<void> }>();
  const reads = new Map<string, { version: number; promise: Promise<string | null> }>();
  const objectURLs = new Map<string, string>();
  const mutations = new Map<string, Promise<unknown>>();

  async function cache(): Promise<AudioDownloadCache> {
    try {
      if (dependencies.openCache) return await dependencies.openCache();
      if (typeof caches === 'undefined') throw new Error('CacheStorage unavailable');
      return await caches.open(CACHE_NAME);
    } catch (error) { throw storageError(error); }
  }

  function mutate<T>(key: string, action: () => Promise<T>): Promise<T> {
    const previous = mutations.get(key) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(action);
    mutations.set(key, next);
    void next.finally(() => { if (mutations.get(key) === next) mutations.delete(key); }).catch(() => {});
    return next;
  }

  async function listDownloaded(server: string): Promise<Set<string>> {
    const prefix = serverPrefix(server);
    const entries = await (await cache()).keys();
    const result = new Set<string>();
    for (const entry of entries) {
      if (!entry.url.startsWith(prefix)) continue;
      try {
        const fingerprint = decodeURIComponent(entry.url.slice(prefix.length));
        if (fingerprint && trackKey(server, fingerprint) === entry.url) result.add(fingerprint);
      } catch { /* Ignore unrelated or malformed cache entries. */ }
    }
    return result;
  }

  async function downloadTrack(server: string, fingerprint: string, url: string): Promise<void> {
    const key = trackKey(server, fingerprint);
    const version = versions.get(key) ?? 0;
    const pending = downloads.get(key);
    if (pending?.version === version) return pending.promise;
    const promise = (async () => {
      await mutations.get(key)?.catch(() => {});
      const store = await cache();
      if (await store.match(key)) return;
      let response: Response;
      try { response = await (dependencies.fetch ?? globalThis.fetch)(url, { cache: 'no-store' }); }
      catch { throw new Error('Could not download this track. Check your connection and try again.'); }
      const blob = await audioBlob(response);
      await mutate(key, async () => {
        if ((versions.get(key) ?? 0) !== version) throw new Error('The download was removed.');
        // Keep only audio data and safe metadata; omit original URLs, cookies, and headers.
        const saved = new Response(blob, { status: 200, headers: {
          'Content-Type': blob.type || 'application/octet-stream',
          'Content-Length': String(blob.size),
        } });
        try { await store.put(key, saved); }
        catch (error) { throw storageError(error); }
      });
    })();
    const entry = { version, promise };
    downloads.set(key, entry);
    try { await promise; }
    finally { if (downloads.get(key) === entry) downloads.delete(key); }
  }

  async function downloadedTrackURL(server: string, fingerprint: string): Promise<string | null> {
    const key = trackKey(server, fingerprint);
    await mutations.get(key)?.catch(() => {});
    const version = versions.get(key) ?? 0;
    const existing = objectURLs.get(key);
    if (existing) return existing;
    const pending = reads.get(key);
    if (pending?.version === version) return pending.promise;
    const promise = (async () => {
      const saved = await (await cache()).match(key);
      if (!saved) return null;
      const blob = await audioBlob(saved);
      if ((versions.get(key) ?? 0) !== version) return null;
      const objectURL = (dependencies.createObjectURL ?? URL.createObjectURL.bind(URL))(blob);
      objectURLs.set(key, objectURL);
      return objectURL;
    })();
    const entry = { version, promise };
    reads.set(key, entry);
    try { return await promise; }
    finally { if (reads.get(key) === entry) reads.delete(key); }
  }

  async function removeDownload(server: string, fingerprint: string): Promise<void> {
    const key = trackKey(server, fingerprint);
    versions.set(key, (versions.get(key) ?? 0) + 1);
    objectURLs.delete(key);
    // An audio element may still use the previous URL. Leave it alive for this document's lifetime.
    await mutate(key, async () => { await (await cache()).delete(key); });
  }

  return { listDownloaded, downloadTrack, downloadedTrackURL, removeDownload };
}

const browserDownloads = createWebDownloads();
export const { listDownloaded, downloadTrack, downloadedTrackURL, removeDownload } = browserDownloads;
