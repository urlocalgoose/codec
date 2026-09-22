import { expect, test } from "bun:test";
import { artworkCacheKey, createArtworkCache } from "./artwork-cache";

const cover = (name: string, query = "") => `https://codec.test/api/v1/tracks/${name}/artwork${query}`;
const image = (size = 4, type = "image/png", status = 200) => new Response(new Uint8Array(size), {
  status, headers: { "Content-Type": type }
});

function fixture(options: { maxEntries?: number; maxBytes?: number; maxAge?: number } = {}) {
  let clock = 0;
  const calls: Array<{ src: string; signal: AbortSignal | undefined; resolve: (response: Response) => void; reject: (reason: unknown) => void }> = [];
  const created: string[] = [];
  const revoked: string[] = [];
  const cache = createArtworkCache({
    ...options, now: () => clock,
    fetch: ((src: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((resolve, reject) => {
      calls.push({ src: String(src), signal: init?.signal ?? undefined, resolve, reject });
    })) as typeof fetch,
    createURL: () => {
      const url = `blob:artwork-test/${created.length + 1}`;
      created.push(url);
      return url;
    },
    revokeURL: url => revoked.push(url)
  });
  return { cache, calls, created, revoked, advance: (milliseconds: number) => { clock += milliseconds; } };
}

test("Codec stream credentials share a key while cover versions and third-party signatures remain distinct", () => {
  expect(artworkCacheKey(cover("isrc%3AUS%2FTEST", "?v=7&access_token=old&signature=one")))
    .toBe(artworkCacheKey(cover("isrc%3AUS%2FTEST", "?v=7&access_token=new&signature=one")));
  expect(artworkCacheKey("https://codec.test/api/v1/playlists/mix/artwork?v=8&access_token=secret"))
    .toBe("https://codec.test/api/v1/playlists/mix/artwork?v=8");
  expect(artworkCacheKey(cover("a", "?v=1"))).not.toBe(artworkCacheKey(cover("a", "?v=2")));
  expect(artworkCacheKey("https://images.test/cover?access_token=one"))
    .not.toBe(artworkCacheKey("https://images.test/cover?access_token=two"));
  expect(artworkCacheKey(cover("a", "?signature=one"))).not.toBe(artworkCacheKey(cover("a", "?signature=two")));
  expect(artworkCacheKey(cover("a"))).not.toBe(artworkCacheKey(cover("a").replace("codec.test", "second.test")));
});

test("concurrent consumers and remounts reuse one fetch and synchronously expose the ready blob", async () => {
  const f = fixture();
  const first = f.cache.acquire(cover("a", "?access_token=old"));
  const second = f.cache.acquire(cover("a", "?access_token=new"));
  expect(f.calls).toHaveLength(1);
  f.calls[0].resolve(image());
  const url = await first.ready;
  expect(await second.ready).toBe(url);
  first.release();
  second.release();
  const remount = f.cache.acquire(cover("a", "?access_token=newer"));
  expect(remount.url).toBe(url);
  expect(f.cache.peek(cover("a"))).toBe(url);
  expect(await remount.ready).toBe(url);
  expect(f.calls).toHaveLength(1);
  expect(f.revoked).toEqual([]);
  remount.release();
  f.cache.clear();
});

test("LRU capacity evicts idle covers while active leases remain valid", async () => {
  const f = fixture({ maxEntries: 2 });
  const first = f.cache.acquire(cover("a")); f.calls[0].resolve(image()); await first.ready;
  const second = f.cache.acquire(cover("b")); f.calls[1].resolve(image()); await second.ready; second.release();
  const third = f.cache.acquire(cover("c")); f.calls[2].resolve(image()); await third.ready; third.release();
  expect(f.cache.peek(cover("a"))).toBe("blob:artwork-test/1");
  expect(f.cache.peek(cover("b"))).toBeNull();
  expect(f.cache.peek(cover("c"))).toBe("blob:artwork-test/3");
  expect(f.revoked).toEqual(["blob:artwork-test/2"]);
  first.release();
  const touch = f.cache.acquire(cover("c")); touch.release();
  const fourth = f.cache.acquire(cover("d")); f.calls[3].resolve(image()); await fourth.ready; fourth.release();
  expect(f.revoked).toEqual(["blob:artwork-test/2", "blob:artwork-test/1"]);
  f.cache.clear();
});

test("byte budget is enforced after active consumers release and repeated release is harmless", async () => {
  const f = fixture({ maxBytes: 5 });
  const first = f.cache.acquire(cover("a")); f.calls[0].resolve(image(4)); await first.ready;
  const second = f.cache.acquire(cover("b")); f.calls[1].resolve(image(4)); await second.ready;
  expect(f.revoked).toEqual([]);
  first.release(); first.release();
  expect(f.cache.peek(cover("a"))).toBeNull();
  expect(f.cache.peek(cover("b"))).toBe("blob:artwork-test/2");
  expect(f.revoked).toEqual(["blob:artwork-test/1"]);
  second.release();
  f.cache.clear();
  expect(f.revoked).toEqual(["blob:artwork-test/1", "blob:artwork-test/2"]);
});

test("TTL refresh keeps the previous cover usable until its active leases release", async () => {
  const f = fixture({ maxAge: 50 });
  const mounted = f.cache.acquire(cover("a")); f.calls[0].resolve(image());
  const oldURL = await mounted.ready;
  f.advance(49);
  const stillFresh = f.cache.acquire(cover("a")); await stillFresh.ready; stillFresh.release();
  expect(f.calls).toHaveLength(1);
  f.advance(1);
  const refresh = f.cache.acquire(cover("a"));
  expect(refresh.url).toBe(oldURL);
  f.calls[1].resolve(image());
  const newURL = await refresh.ready;
  expect(newURL).not.toBe(oldURL);
  expect(f.revoked).not.toContain(oldURL);
  expect(f.cache.peek(cover("a"))).toBe(newURL);
  mounted.release();
  refresh.release();
  expect(f.revoked.filter(url => url === oldURL)).toHaveLength(1);
  f.cache.clear();
});

test("failed refresh retains the usable old cover and permits a later retry", async () => {
  const f = fixture({ maxAge: 20 });
  const mounted = f.cache.acquire(cover("a")); f.calls[0].resolve(image()); const oldURL = await mounted.ready;
  f.advance(20);
  const failure = f.cache.acquire(cover("a"));
  f.calls[1].reject(new TypeError("Network request failed"));
  await expect(failure.ready).rejects.toThrow();
  expect(f.cache.peek(cover("a"))).toBe(oldURL);
  expect(f.revoked).toEqual([]);
  failure.release();
  const retry = f.cache.acquire(cover("a")); f.calls[2].resolve(image());
  expect(await retry.ready).not.toBe(oldURL);
  mounted.release(); retry.release(); f.cache.clear();
});

test.each([
  ["unauthorized", () => image(4, "image/png", 401)],
  ["partial", () => image(4, "image/png", 206)],
  ["HTML", () => image(4, "text/html")],
  ["empty", () => image(0)],
  ["oversized", () => image(8 * 1024 * 1024 + 1)]
] as const)("%s artwork cannot poison the cache", async (_name, response) => {
  const f = fixture();
  const rejected = f.cache.acquire(cover("a")); f.calls[0].resolve(response());
  await expect(rejected.ready).rejects.toThrow();
  expect(f.cache.peek(cover("a"))).toBeNull();
  expect(f.created).toEqual([]);
  rejected.release();
  const retry = f.cache.acquire(cover("a")); f.calls[1].resolve(image());
  expect(await retry.ready).toBe("blob:artwork-test/1");
  retry.release(); f.cache.clear();
});

test("auth clear aborts pending work and late old responses cannot replace a new account's cover", async () => {
  const f = fixture();
  const old = f.cache.acquire(cover("a", "?access_token=old-account"));
  const oldResult = old.ready.catch(error => error);
  f.cache.clear();
  expect(f.calls[0].signal?.aborted).toBe(true);
  expect(f.cache.generation).toBe(1);
  const current = f.cache.acquire(cover("a", "?access_token=new-account"));
  f.calls[0].resolve(image());
  expect(await oldResult).toMatchObject({ name: "AbortError" });
  expect(f.created).toEqual([]);
  f.calls[1].resolve(image());
  expect(await current.ready).toBe("blob:artwork-test/1");
  old.release();
  expect(f.cache.peek(cover("a"))).toBe("blob:artwork-test/1");
  expect(f.revoked).toEqual([]);
  current.release(); f.cache.clear();
});

test("clearing completed artwork revokes it once and prevents reuse", async () => {
  const f = fixture();
  const old = f.cache.acquire(cover("a")); f.calls[0].resolve(image()); await old.ready;
  f.cache.clear(); f.cache.clear(); old.release();
  expect(f.revoked).toEqual(["blob:artwork-test/1"]);
  expect(f.cache.peek(cover("a"))).toBeNull();
  const next = f.cache.acquire(cover("a"));
  expect(next.url).toBeNull();
  f.calls[1].resolve(image()); await next.ready; next.release(); f.cache.clear();
});

test("already-local images do not allocate or fetch cache entries", async () => {
  const f = fixture();
  for (const src of ["data:image/png;base64,AA==", "blob:https://codec.test/local", "asset://localhost/art.png", "tauri://localhost/art.png"]) {
    const lease = f.cache.acquire(src);
    expect(lease.url).toBe(src);
    expect(await lease.ready).toBe(src);
    lease.release();
  }
  expect(f.calls).toEqual([]);
  expect(f.created).toEqual([]);
  f.cache.clear();
});
