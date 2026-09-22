import { describe, expect, test } from 'bun:test';
import { createWebDownloads, type AudioDownloadCache } from './web-downloads';

class MemoryCache implements AudioDownloadCache {
  entries = new Map<string, Response>();
  async match(key: string) { return this.entries.get(key)?.clone(); }
  async put(key: string, response: Response) { this.entries.set(key, response.clone()); }
  async delete(key: string) { return this.entries.delete(key); }
  async keys() { return [...this.entries.keys()].map((key) => new Request(key)); }
}

const server = 'https://music.example.com';
const audio = () => new Response('ID3-sample-audio', { headers: { 'Content-Type': 'audio/mpeg' } });
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

describe('browser downloads', () => {
  test('a canceled storage wait does not trap an immediate retry in the old download', async () => {
    const cache = new MemoryCache();
    const opened = deferred<AudioDownloadCache>();
    const started = deferred<void>();
    const controller = new AbortController();
    let fetches = 0;
    const api = createWebDownloads({ openCache: async () => { started.resolve(); return opened.promise; }, fetch: async () => { fetches++; return audio(); } });
    const first = api.downloadTrack(server, 'fp', 'https://audio', { signal: controller.signal }).catch(error => error);
    await started.promise;
    controller.abort();
    const retry = api.downloadTrack(server, 'fp', 'https://audio', { signal: new AbortController().signal });
    opened.resolve(cache);
    expect((await first).name).toBe('AbortError');
    await retry;
    expect(fetches).toBe(1);
    expect(cache.entries.size).toBe(1);
  });

  test('reports byte progress, saves only the complete file, and clears the idle timer', async () => {
    const cache = new MemoryCache();
    let body!: ReadableStreamDefaultController<Uint8Array>;
    let requestSignal: AbortSignal | undefined;
    const started = deferred<void>();
    const progress: number[] = [];
    const api = createWebDownloads({ openCache: async () => cache, idleTimeoutMs: 30, fetch: async (_url, options) => {
      requestSignal = options?.signal as AbortSignal;
      return new Response(new ReadableStream({ start(controller) { body = controller; started.resolve(); } }), { headers: { 'Content-Type': 'audio/mpeg', 'Content-Length': '9' } });
    } });
    const download = api.downloadTrack(server, 'fp', 'https://audio', { onProgress: (loaded, total) => { expect(total).toBe(9); progress.push(loaded); } });
    await started.promise;
    body.enqueue(new TextEncoder().encode('ID3-'));
    expect(cache.entries.size).toBe(0);
    body.enqueue(new TextEncoder().encode('audio')); body.close();
    await download;
    await new Promise(resolve => setTimeout(resolve, 40));
    expect(progress.at(-1)).toBe(9);
    expect(requestSignal?.aborted).toBe(false);
    expect(cache.entries.size).toBe(1);
  });

  test.each(['headers', 'body'])('times out stalled %s without saving a partial file and allows retry', async (phase) => {
    const cache = new MemoryCache();
    let canceled = false, attempts = 0;
    const api = createWebDownloads({ openCache: async () => cache, idleTimeoutMs: 15, fetch: async () => {
      if (++attempts > 1) return audio();
      if (phase === 'headers') return new Promise<Response>(() => {});
      return new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('ID3-')); }, cancel() { canceled = true; } }), { headers: { 'Content-Type': 'audio/mpeg' } });
    } });
    await expect(api.downloadTrack(server, 'fp', 'https://audio')).rejects.toThrow('stalled');
    expect(cache.entries.size).toBe(0);
    if (phase === 'body') expect(canceled).toBe(true);
    await api.downloadTrack(server, 'fp', 'https://audio');
    expect(cache.entries.size).toBe(1);
  });

  test('canceling a response body releases the reader without storing partial audio', async () => {
    const cache = new MemoryCache();
    const controller = new AbortController();
    const progress = deferred<void>();
    let canceled = false;
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => new Response(new ReadableStream({
      start(body) { body.enqueue(new TextEncoder().encode('ID3-')); }, cancel() { canceled = true; }
    }), { headers: { 'Content-Type': 'audio/mpeg' } }) });
    const pending = api.downloadTrack(server, 'fp', 'https://audio', { signal: controller.signal, onProgress: loaded => { if (loaded) progress.resolve(); } });
    const outcome = pending.catch(error => error);
    await progress.promise; controller.abort();
    expect((await outcome).name).toBe('AbortError');
    expect(canceled).toBe(true);
    expect(cache.entries.size).toBe(0);
  });

  test('normalizes server scope and never stores stream tokens or unsafe response headers', async () => {
    const cache = new MemoryCache();
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => new Response('ID3-audio', {
      headers: { 'Content-Type': 'audio/mpeg', 'Set-Cookie': 'secret', 'X-Original-URL': '?token=secret' },
    }) });
    await api.downloadTrack('https://user:password@MUSIC.example.com:443/?token=secret#private', 'fp/1', 'https://music.example.com/audio?token=stream-secret');
    expect(await api.listDownloaded(server)).toEqual(new Set(['fp/1']));
    expect(await api.listDownloaded('https://other.example.com')).toEqual(new Set());
    expect(await api.listDownloaded(`${server}/other-path`)).toEqual(new Set());
    const [key, response] = [...cache.entries][0];
    expect(key).not.toMatch(/secret|password|user|token/);
    expect([...response.headers.keys()].sort()).toEqual(['content-length', 'content-type']);
  });

  test('coalesces concurrent downloads and avoids downloading an existing file again', async () => {
    const cache = new MemoryCache();
    const gate = deferred<Response>();
    let fetches = 0;
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => { fetches++; return gate.promise; } });
    const a = api.downloadTrack(server, 'fp', 'https://audio');
    const b = api.downloadTrack(`${server}/`, 'fp', 'https://audio');
    gate.resolve(audio());
    await Promise.all([a, b]);
    await api.downloadTrack(server, 'fp', 'https://audio');
    expect(fetches).toBe(1);
    expect(cache.entries.size).toBe(1);
  });

  test('reads persisted audio entirely offline and returns one stable Blob URL for concurrent reads', async () => {
    const cache = new MemoryCache();
    const writer = createWebDownloads({ openCache: async () => cache, fetch: async () => audio() });
    await writer.downloadTrack(server, 'fp', 'https://audio');
    let blobs = 0;
    const reader = createWebDownloads({ openCache: async () => cache, fetch: async () => { throw new Error('Offline'); }, createObjectURL: () => `blob:audio-${++blobs}` });
    expect(await Promise.all([reader.downloadedTrackURL(server, 'fp'), reader.downloadedTrackURL(server, 'fp')])).toEqual(['blob:audio-1', 'blob:audio-1']);
    expect(await reader.downloadedTrackURL(server, 'fp')).toBe('blob:audio-1');
    expect(await reader.downloadedTrackURL(server, 'missing')).toBeNull();
    expect(blobs).toBe(1);
  });

  test('removal prevents future reads while an already-created playback URL remains valid', async () => {
    const cache = new MemoryCache();
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => audio() });
    await api.downloadTrack(server, 'fp', 'https://audio');
    const url = await api.downloadedTrackURL(server, 'fp');
    await api.removeDownload(server, 'fp');
    expect(await api.downloadedTrackURL(server, 'fp')).toBeNull();
    expect(await api.listDownloaded(server)).toEqual(new Set());
    // Fetching a local Blob URL does not touch the network and proves it was not revoked.
    expect(await (await fetch(url!)).text()).toBe('ID3-sample-audio');
    URL.revokeObjectURL(url!);
  });

  test('removing a download while its fetch is pending cannot resurrect the file', async () => {
    const cache = new MemoryCache();
    const gate = deferred<Response>();
    const started = deferred<void>();
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => { started.resolve(); return gate.promise; } });
    const pending = api.downloadTrack(server, 'fp', 'https://audio');
    const outcome = pending.then(() => null, (error: Error) => error);
    await started.promise;
    await api.removeDownload(server, 'fp');
    gate.resolve(audio());
    expect((await outcome)?.message).toContain('removed');
    expect(cache.entries.size).toBe(0);
  });

  test('removal serializes behind an in-progress cache write', async () => {
    const cache = new MemoryCache();
    const started = deferred<void>();
    const finish = deferred<void>();
    cache.put = async (key, value) => { started.resolve(); await finish.promise; cache.entries.set(key, value.clone()); };
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => audio() });
    const download = api.downloadTrack(server, 'fp', 'https://audio');
    await started.promise;
    const remove = api.removeDownload(server, 'fp');
    finish.resolve();
    await Promise.all([download, remove]);
    expect(cache.entries.size).toBe(0);
  });

  test('reads and replacement downloads wait for a pending removal', async () => {
    const cache = new MemoryCache();
    let fetches = 0;
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => { fetches++; return audio(); } });
    await api.downloadTrack(server, 'fp', 'https://audio');
    const started = deferred<void>();
    const finish = deferred<void>();
    cache.delete = async (key) => { started.resolve(); await finish.promise; return cache.entries.delete(key); };
    const removal = api.removeDownload(server, 'fp');
    await started.promise;
    const read = api.downloadedTrackURL(server, 'fp');
    const replacement = api.downloadTrack(server, 'fp', 'https://audio');
    finish.resolve();
    await removal;
    expect(await read).toBeNull();
    await replacement;
    expect(fetches).toBe(2);
    expect(await api.listDownloaded(server)).toEqual(new Set(['fp']));
  });

  test.each([
    ['HTTP error', () => new Response('no', { status: 403, headers: { 'Content-Type': 'audio/mpeg' } })],
    ['partial status', () => new Response('ID3-audio', { status: 206, headers: { 'Content-Type': 'audio/mpeg' } })],
    ['partial header', () => new Response('ID3-audio', { headers: { 'Content-Type': 'audio/mpeg', 'Content-Range': 'bytes 0-8/20' } })],
    ['empty audio', () => new Response('', { headers: { 'Content-Type': 'audio/mpeg' } })],
    ['HTML page', () => new Response('<html>login</html>', { headers: { 'Content-Type': 'text/html' } })],
    ['HTML with audio MIME', () => new Response('  <!doctype html><title>login</title>', { headers: { 'Content-Type': 'audio/mpeg' } })],
    ['JSON with audio MIME', () => new Response('{"error":"unauthorized"}', { headers: { 'Content-Type': 'audio/mpeg' } })],
    ['incomplete body', () => new Response('ID3-audio', { headers: { 'Content-Type': 'audio/mpeg', 'Content-Length': '100' } })],
    ['unknown binary', () => new Response('not audio', { headers: { 'Content-Type': 'application/octet-stream' } })],
    ['streaming playlist', () => new Response('#EXTM3U\nhttps://audio', { headers: { 'Content-Type': 'audio/x-mpegurl' } })],
  ])('rejects %s without saving it', async (_name, response) => {
    const cache = new MemoryCache();
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => response() });
    await expect(api.downloadTrack(server, 'fp', 'https://audio')).rejects.toThrow();
    expect(cache.entries.size).toBe(0);
  });

  test('accepts recognizable audio served with a generic binary MIME', async () => {
    const cache = new MemoryCache();
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => new Response('fLaC-audio', { headers: { 'Content-Type': 'application/octet-stream' } }) });
    await api.downloadTrack(server, 'fp', 'https://audio');
    expect(await api.listDownloaded(server)).toEqual(new Set(['fp']));
  });

  test('reports unavailable storage before attempting a download', async () => {
    let fetches = 0;
    const api = createWebDownloads({ openCache: async () => { throw new Error('SecurityError'); }, fetch: async () => { fetches++; return audio(); } });
    await expect(api.downloadTrack(server, 'fp', 'https://audio')).rejects.toThrow('unavailable in this browser');
    expect(fetches).toBe(0);
  });

  test('reports quota failures and permits retry after a failed write', async () => {
    const cache = new MemoryCache();
    const put = cache.put.bind(cache);
    cache.put = async () => { throw new DOMException('full', 'QuotaExceededError'); };
    const api = createWebDownloads({ openCache: async () => cache, fetch: async () => audio() });
    await expect(api.downloadTrack(server, 'fp', 'https://audio')).rejects.toThrow('Not enough browser storage');
    cache.put = put;
    await api.downloadTrack(server, 'fp', 'https://audio');
    expect(await api.listDownloaded(server)).toEqual(new Set(['fp']));
  });
});
