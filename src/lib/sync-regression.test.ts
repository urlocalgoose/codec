import { afterEach, expect, test } from "bun:test";
import {
  fetchRemoteLibrary, normalizeLibrary, refreshSyncStreamToken, validateSyncServer,
  removeTrackFromRemotePlaylist, renameRemotePlaylist,
  resetPlaybackCommandQueue, sendPlaybackCommandV2, setSyncAuthToken, trackAudioUrl,
  type PlaybackCommandV2, type PlaybackContextV2
} from "./sync";
import { findTrackByReference, playlistTracks, tracksFromReferences } from "./library";
import type { Library, Track, TrackReference } from "./types";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

afterEach(() => {
  setSyncAuthToken("");
  resetPlaybackCommandQueue();
});

function queueCommand(id: string, revision = 10, tracks: string[] = [id]): PlaybackCommandV2 {
  return {
    command_id: id, device_id: "web", kind: "set_queue", expectedRevision: revision,
    context: {
      playback_source: [], playback_index: 0,
      queued_tracks: tracks.map((track) => ({ id: track, path: track, fingerprint: track })),
      play_history: [], shuffle: false, repeat: "off"
    }
  };
}

function playbackServer() {
  let revision = 10;
  let context: PlaybackContextV2 | undefined;
  const requests: Request[] = [];
  const fetcher = (async (url: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(url, init);
    requests.push(request);
    const expected = request.headers.get("If-Match");
    if (expected && expected !== `"${revision}"`) return new Response(null, { status: 409 });
    const command = await request.json() as PlaybackCommandV2;
    context = command.context ?? context;
    return Response.json({ revision: ++revision, context });
  }) as typeof fetch;
  return { fetcher, requests, foreignChange: () => revision++, queue: () => context?.queued_tracks.map((track) => track.id) };
}

test("rapid cumulative queue edits advance through their own acknowledged revisions", async () => {
  const server = playbackServer();
  const gate = deferred<void>();
  let count = 0;
  const fetcher = (async (url: RequestInfo | URL, init?: RequestInit) => {
    if (++count === 1) await gate.promise;
    return server.fetcher(url, init);
  }) as typeof fetch;
  const pending = [
    sendPlaybackCommandV2("http://codec.test", queueCommand("a"), fetcher),
    sendPlaybackCommandV2("http://codec.test", queueCommand("b", 10, ["a", "b"]), fetcher),
    sendPlaybackCommandV2("http://codec.test", queueCommand("c", 10, ["a", "b", "c"]), fetcher)
  ];
  await Promise.resolve();
  expect(count).toBe(1);
  gate.resolve();
  expect((await Promise.all(pending)).map((state) => state.revision)).toEqual([11, 12, 13]);
  expect(server.requests.map((request) => request.headers.get("If-Match"))).toEqual(['"10"', '"11"', '"12"']);
  expect(server.queue()).toEqual(["a", "b", "c"]);
});

test("a foreign change between queued edits still conflicts and is never retried blindly", async () => {
  const server = playbackServer();
  let count = 0;
  const fetcher = (async (url: RequestInfo | URL, init?: RequestInit) => {
    const response = await server.fetcher(url, init);
    if (++count === 1) server.foreignChange();
    return response;
  }) as typeof fetch;
  const first = sendPlaybackCommandV2("http://codec.test", queueCommand("a"), fetcher);
  const second = sendPlaybackCommandV2("http://codec.test", queueCommand("b", 10, ["a", "b"]), fetcher);
  await first;
  await expect(second).rejects.toThrow("Playback changed on another device");
  expect(server.requests.map((request) => request.headers.get("If-Match"))).toEqual(['"10"', '"11"']);
  expect(server.queue()).toEqual(["a"]);
});

test("an unguarded pause can precede a queue edit without a false conflict", async () => {
  const server = playbackServer();
  const first = sendPlaybackCommandV2("http://codec.test", { command_id: "pause", device_id: "web", kind: "pause" }, server.fetcher);
  const second = sendPlaybackCommandV2("http://codec.test", queueCommand("a"), server.fetcher);
  await Promise.all([first, second]);
  expect(server.requests[1].headers.get("If-Match")).toBe('"11"');
  expect(server.queue()).toEqual(["a"]);
});

test("an unguarded command cannot hide a foreign revision gap", async () => {
  const server = playbackServer();
  server.foreignChange();
  const first = sendPlaybackCommandV2("http://codec.test", { command_id: "pause", device_id: "web", kind: "pause" }, server.fetcher);
  const second = sendPlaybackCommandV2("http://codec.test", queueCommand("a"), server.fetcher);
  await first;
  await expect(second).rejects.toThrow("Playback changed on another device");
  expect(server.requests[1].headers.get("If-Match")).toBe('"10"');
  expect(server.queue()).toBeUndefined();
});

test("server-side next does not let a stale queued snapshot restore consumed tracks", async () => {
  const server = playbackServer();
  const first = sendPlaybackCommandV2("http://codec.test", { command_id: "next", device_id: "web", kind: "next" }, server.fetcher);
  const second = sendPlaybackCommandV2("http://codec.test", queueCommand("a"), server.fetcher);
  await first;
  await expect(second).rejects.toThrow("Playback changed on another device");
  expect(server.requests[1].headers.get("If-Match")).toBe('"10"');
});

test("a later independent stale snapshot does not inherit an earlier burst's revisions", async () => {
  const server = playbackServer();
  await sendPlaybackCommandV2("http://codec.test", queueCommand("a"), server.fetcher);
  await expect(sendPlaybackCommandV2("http://codec.test", queueCommand("b"), server.fetcher)).rejects.toThrow("Playback changed on another device");
  expect(server.queue()).toEqual(["a"]);
});

test("a failed request does not fabricate an acknowledged revision or stop the queue", async () => {
  const server = playbackServer();
  let count = 0;
  const fetcher = (async (url: RequestInfo | URL, init?: RequestInit) => ++count === 1
    ? new Response(null, { status: 503 }) : server.fetcher(url, init)) as typeof fetch;
  const first = sendPlaybackCommandV2("http://codec.test", queueCommand("a"), fetcher);
  const second = sendPlaybackCommandV2("http://codec.test", queueCommand("b", 10, ["a", "b"]), fetcher);
  await expect(first).rejects.toThrow("503");
  expect((await second).revision).toBe(11);
  expect(server.requests[0].headers.get("If-Match")).toBe('"10"');
  expect(server.queue()).toEqual(["a", "b"]);
});

for (const reset of ["server", "auth", "disconnect"] as const) {
  test(`${reset} changes cancel unsent commands and isolate the new connection`, async () => {
    setSyncAuthToken("old-token");
    const delayed = deferred<Response>();
    let oldRequests = 0;
    const oldFetcher = (async (_url: RequestInfo | URL, _init?: RequestInit) => { oldRequests++; return delayed.promise; }) as typeof fetch;
    const first = sendPlaybackCommandV2("http://old.test", queueCommand("a"), oldFetcher);
    const second = sendPlaybackCommandV2("http://old.test", queueCommand("b"), oldFetcher);
    const oldResults = Promise.allSettled([first, second]);
    await Promise.resolve();
    expect(oldRequests).toBe(1);
    if (reset === "auth") setSyncAuthToken("new-token");
    if (reset === "disconnect") resetPlaybackCommandQueue();
    const next = playbackServer();
    const result = await sendPlaybackCommandV2(reset === "server" ? "http://new.test" : "http://old.test", queueCommand("c"), next.fetcher);
    expect(result.revision).toBe(11);
    expect(next.requests[0].headers.get("Authorization")).toBe(reset === "auth" ? "Bearer new-token" : "Bearer old-token");
    delayed.resolve(Response.json({ revision: 99 }));
    expect((await oldResults).every((result) => result.status === "rejected")).toBe(true);
    expect(oldRequests).toBe(1);
    expect(next.requests[0].headers.get("If-Match")).toBe('"10"');
  });
}

test("concurrent track loads reuse one valid stream token", async () => {
  setSyncAuthToken("test-secret");
  const response = deferred<Response>();
  let requests = 0;
  const fetcher = (async (_input: RequestInfo | URL, _init?: RequestInit) => { requests++; return response.promise; }) as typeof fetch;
  const first = refreshSyncStreamToken("http://codec.test", fetcher);
  const second = refreshSyncStreamToken("http://codec.test", fetcher);
  expect(requests).toBe(1);
  response.resolve(Response.json({ token: "stream_reused", expires_at: Date.now() / 1000 + 900 }));
  await Promise.all([first, second]);
  const url = trackAudioUrl("http://codec.test", "same");
  await refreshSyncStreamToken("http://codec.test", fetcher);
  expect(requests).toBe(1);
  expect(trackAudioUrl("http://codec.test", "same")).toBe(url);
});

test("an old connection cannot replace the new connection's token", async () => {
  setSyncAuthToken("old-secret");
  const old = deferred<Response>();
  const pending = refreshSyncStreamToken("http://old.test", (async (_input: RequestInfo | URL, _init?: RequestInit) => old.promise) as typeof fetch);
  setSyncAuthToken("new-secret");
  await refreshSyncStreamToken("http://new.test", (async (_input: RequestInfo | URL, _init?: RequestInit) => Response.json({ token: "stream_new", expires_at: Date.now() / 1000 + 900 })) as typeof fetch);
  old.resolve(Response.json({ token: "stream_old", expires_at: Date.now() / 1000 + 900 }));
  await pending;
  expect(new URL(trackAudioUrl("http://new.test", "a")).searchParams.get("access_token")).toBe("stream_new");
});

test("normalizing artwork repeatedly replaces rather than duplicates credentials", () => {
  setSyncAuthToken("test-secret");
  const once = normalizeLibrary({ tracks: [{ artwork_url: "http://codec.test/api/v1/tracks/a/artwork?access_token=old&v=2" } as Track] }, "http://codec.test");
  const twice = normalizeLibrary(once, "http://codec.test");
  const url = new URL(twice.tracks[0].artwork_url!);
  expect(url.searchParams.getAll("access_token")).toEqual(["test-secret"]);
  expect(url.searchParams.get("v")).toBe("2");
});

test("artwork credentials stay scoped to this server's protected endpoints", () => {
  setSyncAuthToken("test-secret");
  const sources = [
    "https://images.test/api/v1/tracks/a/artwork?v=2",
    "https://images.test/cover.jpg?access_token=external-signature",
    "http://codec.test/public/cover.svg",
    "http://codec.test.evil.test/api/v1/tracks/a/artwork",
    "data:image/png;base64,fixture"
  ];
  const normalized = normalizeLibrary({tracks: sources.map(artwork_url => ({artwork_url} as Track))}, "http://codec.test");
  expect(normalized.tracks.map(track => track.artwork_url)).toEqual(sources);
  expect(normalizeLibrary({tracks: [{artwork_url: "http://codec.test/api/v1/tracks/a/artwork"} as Track]}).tracks[0].artwork_url)
    .toBe("http://codec.test/api/v1/tracks/a/artwork");
});

test("relative artwork respects a server path prefix and retains cover versions", () => {
  setSyncAuthToken("test-secret");
  const normalized = normalizeLibrary({tracks: [{artwork_url: "/codec/api/v1/tracks/a/artwork?v=3"} as Track]}, "https://codec.test/codec");
  const url = new URL(normalized.tracks[0].artwork_url!);
  expect(url.origin).toBe("https://codec.test");
  expect(url.pathname).toBe("/codec/api/v1/tracks/a/artwork");
  expect(url.searchParams.get("v")).toBe("3");
  expect(url.searchParams.get("access_token")).toBe("test-secret");
});

test("unchanged remote libraries reuse the same snapshot and send a validator", async () => {
  const requests: Request[] = [];
  const fetcher = (async (url: RequestInfo | URL, init?: RequestInit) => {
    requests.push(new Request(url, init));
    return requests.length === 1
      ? Response.json({ tracks: [] }, { headers: { ETag: '"version-a"' } })
      : new Response(null, { status: 304 });
  }) as typeof fetch;
  const first = await fetchRemoteLibrary("http://etag.test", fetcher);
  const second = await fetchRemoteLibrary("http://etag.test", fetcher);
  expect(second).toBe(first);
  expect(requests[1].headers.get("If-None-Match")).toBe('"version-a"');
});

test("playback commands retain order despite a slow first request", async () => {
  const firstResponse = deferred<Response>();
  const sent: string[] = [];
  const fetcher = (async (_url: RequestInfo | URL, init?: RequestInit) => {
    sent.push(JSON.parse(String(init?.body)).kind);
    if (sent.length === 1) return firstResponse.promise;
    return Response.json({ revision: 2, state: "playing" });
  }) as typeof fetch;
  const pause = sendPlaybackCommandV2("http://codec.test", { command_id: "1", device_id: "web", kind: "pause" }, fetcher);
  const play = sendPlaybackCommandV2("http://codec.test", { command_id: "2", device_id: "web", kind: "play" }, fetcher);
  await Promise.resolve();
  expect(sent).toEqual(["pause"]);
  firstResponse.resolve(Response.json({ revision: 1, state: "paused" }));
  await Promise.all([pause, play]);
  expect(sent).toEqual(["pause", "play"]);
});

test("a rejected command does not block subsequent commands", async () => {
  let count = 0;
  const fetcher = (async (_input: RequestInfo | URL, _init?: RequestInit) => ++count === 1 ? new Response(null, { status: 503 }) : Response.json({ revision: 3 })) as typeof fetch;
  await expect(sendPlaybackCommandV2("http://codec.test", { command_id: "1", device_id: "web", kind: "pause" }, fetcher)).rejects.toThrow("503");
  expect((await sendPlaybackCommandV2("http://codec.test", { command_id: "2", device_id: "web", kind: "play" }, fetcher)).revision).toBe(3);
});

test("playlist order survives resolution, including missing tracks", () => {
  const library = { tracks: [{ id: "A", path: "A", fingerprint: "a" }, { id: "B", path: "B", fingerprint: "b" }] } as Library;
  expect(playlistTracks(library, { id: "p", name: "p", path: "p", is_liked: false, track_ids: ["B", "missing", "A"] }).map((t) => t.id)).toEqual(["B", "A"]);
});

test("large contexts index the library once and invalidate with new track arrays", () => {
  let pathReads = 0;
  const tracks = Array.from({ length: 1000 }, (_, i) => ({ id: `t${i}`, fingerprint: `f${i}`, get path() { pathReads++; return `p${i}`; } })) as Track[];
  const library = { tracks } as Library;
  const references = tracks.map((t, i) => ({ id: t.id, path: `p${i}`, fingerprint: t.fingerprint })) as TrackReference[];
  expect(tracksFromReferences(library, references)).toHaveLength(1000);
  expect(pathReads).toBeLessThanOrEqual(3000);
  const readsAfterIndex = pathReads;
  tracksFromReferences(library, references);
  expect(pathReads).toBe(readsAfterIndex);
  const updated = { ...tracks[0], title: "Updated" };
  expect(findTrackByReference({ ...library, tracks: [updated] }, references[0])).toBe(updated);
});

test("queue revisions use an HTTP precondition without changing the JSON command", async () => {
  let received: Request | undefined;
  const fetcher = (async (url: RequestInfo | URL, init?: RequestInit) => {
    received = new Request(url, init);
    return new Response(null, { status: 409 });
  }) as typeof fetch;
  await expect(sendPlaybackCommandV2("http://codec.test", { command_id: "queue", device_id: "web", kind: "set_queue", expectedRevision: 7 }, fetcher)).rejects.toThrow("Playback changed on another device");
  expect(received!.headers.get("If-Match")).toBe('"7"');
  expect(await received!.json()).toEqual({ command_id: "queue", device_id: "web", kind: "set_queue" });
});

test("web playlist removal uses the authenticated membership endpoint", async () => {
  setSyncAuthToken("playlist-secret");
  let received!: Request;
  await removeTrackFromRemotePlaylist("http://codec.test/", "playlist/mix", "song#1", (async (url: RequestInfo | URL, init?: RequestInit) => {
    received = new Request(url, init);
    return Response.json({ track_ids: [] });
  }) as typeof fetch);
  expect(received.url).toBe("http://codec.test/api/v1/playlists/playlist%2Fmix/tracks/song%231");
  expect(received.method).toBe("DELETE");
  expect(received.headers.get("Authorization")).toBe("Bearer playlist-secret");
});

test("web playlist rename sends only the name to the narrow update endpoint", async () => {
  setSyncAuthToken("playlist-secret");
  let received!: Request;
  await renameRemotePlaylist("http://codec.test/", "playlist/mix", "Road trip", (async (url: RequestInfo | URL, init?: RequestInit) => {
    received = new Request(url, init);
    return new Response(null, { status: 204 });
  }) as typeof fetch);
  expect(received.url).toBe("http://codec.test/api/v1/playlists/playlist%2Fmix/name");
  expect(received.method).toBe("PUT");
  expect(received.headers.get("Authorization")).toBe("Bearer playlist-secret");
  expect(await received.json()).toEqual({ name: "Road trip" });
});

test("failed playlist mutations surface errors for UI reconciliation", async () => {
  const fetcher = (async (_url: RequestInfo | URL, _init?: RequestInit) => new Response(null, { status: 404 })) as typeof fetch;
  await expect(removeTrackFromRemotePlaylist("http://codec.test", "missing", "song", fetcher)).rejects.toThrow("Could not remove from playlist");
  await expect(renameRemotePlaylist("http://codec.test", "missing", "Renamed", fetcher)).rejects.toThrow("Could not rename playlist");
});


test("WebKit transport errors become actionable connection messages", async () => {
  const fetcher = (async () => { throw new TypeError("FetchEvent.respondWith received an error: TypeError: Load failed"); }) as unknown as typeof fetch;
  await expect(validateSyncServer("https://codec.test", fetcher)).rejects.toThrow("Could not reach your Codec server. Check the server address or try again.");
});

test("connection request cancellation keeps its abort identity", async () => {
  const aborted = new DOMException("Request cancelled", "AbortError");
  const fetcher = (async () => { throw aborted; }) as unknown as typeof fetch;
  await expect(validateSyncServer("https://codec.test", fetcher)).rejects.toBe(aborted);
});
