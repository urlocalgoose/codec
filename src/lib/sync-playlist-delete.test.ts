import { afterEach, expect, test } from "bun:test";
import { deleteRemotePlaylist, setSyncAuthToken } from "./sync";

afterEach(() => setSyncAuthToken(""));

test("delete playlist sends one authenticated container DELETE and accepts empty 204", async () => {
  setSyncAuthToken("playlist-fixture-token");
  const requests: Request[] = [];
  await deleteRemotePlaylist("https://codec.test/base/", "mix/summer#1", (async (url: RequestInfo | URL, init?: RequestInit) => {
    requests.push(new Request(url, init));
    return new Response(null, { status: 204 });
  }) as typeof fetch);
  expect(requests).toHaveLength(1);
  expect(requests[0].url).toBe("https://codec.test/base/api/v1/playlists/mix%2Fsummer%231");
  expect(requests[0].method).toBe("DELETE");
  expect(requests[0].headers.get("Authorization")).toBe("Bearer playlist-fixture-token");
  expect(await requests[0].text()).toBe("");
});

test("same-named playlists remain distinct and deletion never calls a track endpoint", async () => {
  const playlists = new Map([["one", { name: "Mix", track_ids: ["song"] }], ["two", { name: "Mix", track_ids: ["song"] }]]);
  const tracks = new Map([["song", { title: "Song", media: "fixture-audio" }]]);
  const requests: string[] = [];
  await deleteRemotePlaylist("https://codec.test", "two", (async (url: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(url, init);
    requests.push(new URL(request.url).pathname);
    expect(request.method).toBe("DELETE");
    expect(new URL(request.url).pathname).toBe("/api/v1/playlists/two");
    playlists.delete("two");
    return new Response(null, { status: 204 });
  }) as typeof fetch);
  expect(requests).toEqual(["/api/v1/playlists/two"]);
  expect([...playlists.keys()]).toEqual(["one"]);
  expect(tracks.get("song")).toEqual({ title: "Song", media: "fixture-audio" });
});

test.each([400, 403, 404, 500])("playlist delete reports rejected status %s without retry", async status => {
  let calls = 0;
  await expect(deleteRemotePlaylist("https://codec.test", "playlist", (async (_url: RequestInfo | URL, _init?: RequestInit) => {
    calls++;
    return new Response(null, { status });
  }) as typeof fetch)).rejects.toThrow();
  expect(calls).toBe(1);
});
