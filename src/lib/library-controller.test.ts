import { expect, test } from "bun:test";
import type { Library, Playlist, Track } from "./types";
import { refreshSyncStreamToken, setSyncAuthToken, trackAudioUrl } from "./sync";

const page = await Bun.file(new URL("../routes/+page.svelte", import.meta.url).pathname).text();

function controllerFunction(name: string) {
  const start = page.search(new RegExp(`  (?:async )?function ${name}\\(`));
  if (start < 0) throw new Error(`Missing controller function ${name}`);
  const lineEnd = page.indexOf("\n", start);
  if (page.slice(start, lineEnd).trimEnd().endsWith("}")) return page.slice(start, lineEnd);
  return page.slice(start, page.indexOf("\n  }", start) + 4);
}

function fixture(): Library {
  return {
    root_path: "loud://remote", scanned_at: 1,
    tracks: [
      { id: "track_a", path: "a", fingerprint: "a", playlist_ids: ["p"], is_liked: false },
      { id: "track_b", path: "b", fingerprint: "b", playlist_ids: ["p"], is_liked: false }
    ] as Track[],
    playlists: [
      { id: "p", name: "First", path: "p", track_ids: ["track_a", "track_b"], is_liked: false },
      { id: "q", name: "Second", path: "q", track_ids: [], is_liked: false },
      { id: "liked", name: "Liked", path: "liked", track_ids: [], is_liked: true }
    ],
    stats: { trackCount: 2, playlistCount: 2, likedCount: 0, albumCount: 0, artistCount: 0, durationSeconds: 0 },
    albums: [], artists: []
  };
}

function controller(initial: Library, api: Record<string, (...args: any[]) => any>) {
  const functions = ["createPlaylistFromLibrary", "commitPlaylistRename", "savePlaylistMemberships", "closePlaylistMembershipModal", "applyLocalPlaylistMemberships", "playlistSelectionForTrack", "refreshRemoteLibraryState", "enqueuePlaylistWrite", "movePlaylistSong", "removePlaylistSong", "addPlaylistSong"].map(controllerFunction).join("\n");
  const source = `
    let library = initial, lastRemoteLibrary = initial, remoteLibraryRefresh = null, remoteLibraryRefreshAgain = false;
    let lastLibraryRefreshAt = 0, syncReadGeneration = 0;
    let rootPath = initial.root_path, syncServerUrl = 'http://codec.test', syncTokenDraft = 'secret';
    let newPlaylistTitle = '', newPlaylistTrack = null, newPlaylistOpen = true, creatingPlaylist = false, createPlaylistError = '', guestMode = false;
    let selectedPlaylist = initial.playlists[0], selectedView = selectedPlaylist.id, editingPlaylistId = selectedPlaylist.id;
    let playlistNameDraft = '', renamingPlaylist = false, errorMessage = '';
    let playlistModalTrack = null, playlistModalSelectionIds = [], savingPlaylistMemberships = false;
    let pendingPlaylistWrites = 0, playlistMutationEpoch = 0, playlistWriteTail = Promise.resolve(), addingSongIDs = new Set();
    let visibleTracks = selectedPlaylist.track_ids.map(id => library.tracks.find(track => track.id === id));
    const isRemoteRoot = path => path.startsWith('loud://');
    const usePlaybackSync = () => true;
    const refreshSyncStreamToken = async () => {};
    const fetchRemoteLibrary = async () => api.fetch();
    const writeCachedLibrary = async () => {};
    const createRemotePlaylist = async (...args) => api.create(...args);
    const renameRemotePlaylist = async (...args) => api.rename(...args);
    const addTrackToRemotePlaylist = async (...args) => api.add(...args);
    const removeTrackFromRemotePlaylist = async (...args) => api.remove(...args);
    const setRemotePlaylistTracks = async (...args) => api.reorder(...args);
    const setTrackLiked = async (...args) => api.like(...args);
    const invoke = async () => {throw new Error('Browser attempted a native command')};
    const loadLibrary = invoke;
    function syncLibrary(next) {library=next;selectedPlaylist=library.playlists.find(item=>item.id===selectedView);visibleTracks=(selectedPlaylist?.track_ids ?? []).map(id=>library.tracks.find(track=>track.id===id)).filter(Boolean)}
    function selectView(view) {selectedView=view;selectedPlaylist=library.playlists.find(item=>item.id===view)}
    function cancelPlaylistRename() {editingPlaylistId='';playlistNameDraft=''}
    ${functions}
    return {
      refresh: refreshRemoteLibraryState,
      create(name, track=null) {newPlaylistTitle=name;newPlaylistTrack=track;return createPlaylistFromLibrary()},
      rename(name) {playlistNameDraft=name;return commitPlaylistRename()},
      openMembership(ids) {playlistModalTrack=library.tracks[0];playlistModalSelectionIds=ids},
      save: savePlaylistMemberships,
      reorder: movePlaylistSong,
      remove: removePlaylistSong,
      add: addPlaylistSong,
      idle: () => playlistWriteTail,
      changeConnection(next) {syncServerUrl='http://new.test';syncTokenDraft='new';syncLibrary(next)},
      changeAuthentication(next) {syncTokenDraft='new';syncLibrary(next)},
      state: () => ({library, selectedView, newPlaylistOpen, createPlaylistError, errorMessage, savingPlaylistMemberships})
    };
  `;
  return new Function("initial", "api", new Bun.Transpiler({ loader: "ts" }).transformSync(source))(initial, api);
}

test("a created playlist opens immediately even when its follow-up refresh is offline", async () => {
  const created: Playlist = { id: "new", name: "Road trip", path: "new", track_ids: [], is_liked: false };
  const c = controller(fixture(), { create: async () => created, fetch: async () => { throw new Error("offline"); } });
  await c.create("Road trip");
  expect(c.state().library.playlists.at(-1)).toEqual(created);
  expect(c.state().library.stats.playlistCount).toBe(3);
  expect(c.state().selectedView).toBe("new");
  expect(c.state().newPlaylistOpen).toBe(false);
  expect(c.state().createPlaylistError).toBe("");
});

test("a successful playlist creation closes its dialog even when adding the first song fails", async () => {
  const initial = fixture();
  const created: Playlist = { id: "new", name: "Road trip", path: "new", track_ids: [], is_liked: false };
  let creates = 0;
  const c = controller(initial, {
    create: async () => { creates++; return created; },
    add: async () => { throw new Error("Could not add the song"); },
    fetch: async () => { throw new Error("offline"); }
  });
  await c.create("Road trip", initial.tracks[0]);
  expect(creates).toBe(1);
  expect(c.state().library.playlists.filter((playlist: Playlist) => playlist.id === "new")).toEqual([created]);
  expect(c.state().library.stats.playlistCount).toBe(3);
  expect(c.state().newPlaylistOpen).toBe(false);
  expect(c.state().createPlaylistError).toBe("");
  expect(c.state().errorMessage).toBe("Could not add the song");
});

test("a committed rename remains visible when the follow-up refresh is offline", async () => {
  const c = controller(fixture(), { rename: async () => {}, fetch: async () => { throw new Error("offline"); } });
  await c.rename("Renamed");
  expect(c.state().library.playlists[0].name).toBe("Renamed");
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_a", "track_b"]);
});

test("partial membership failure reapplies the server snapshot already cached by SSE", async () => {
  let remote = fixture();
  let c: ReturnType<typeof controller>;
  c = controller(remote, {
    fetch: async () => remote,
    remove: async () => {
      remote = {
        ...remote,
        tracks: remote.tracks.map((track) => track.id === "track_a" ? { ...track, playlist_ids: [] } : track),
        playlists: remote.playlists.map((playlist) => playlist.id === "p" ? { ...playlist, track_ids: ["track_b"] } : playlist)
      };
      await c.refresh(); // An SSE library event arrives between the writes.
    },
    add: async () => { throw new Error("Add failed"); }
  });
  c.openMembership(["q"]);
  await c.save();
  expect(c.state().library).toBe(remote);
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_b"]);
  expect(c.state().errorMessage).toBe("Add failed");
  expect(c.state().savingPlaylistMemberships).toBe(false);
});

test("membership saves stay locked until requests finish and preserve existing track order", async () => {
  let release!: () => void;
  const pending = new Promise<void>((resolve) => { release = resolve; });
  let adds = 0;
  const initial = fixture();
  const c = controller(initial, { add: async () => { adds++; await pending; }, fetch: async () => initial });
  c.openMembership(["p", "q"]);
  const saving = c.save();
  expect(c.state().savingPlaylistMemberships).toBe(true);
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_a", "track_b"]);
  c.openMembership(["p"]);
  await c.save();
  expect(adds).toBe(1);
  release();
  await saving;
  expect(c.state().savingPlaylistMemberships).toBe(false);
});

test("changing servers during a membership save cancels remaining writes and stale rollback", async () => {
  let release!: () => void;
  const pending = new Promise<void>((resolve) => { release = resolve; });
  const initial = fixture();
  let adds = 0;
  const c = controller(initial, { remove: async () => pending, add: async () => { adds++; }, fetch: async () => initial });
  c.openMembership(["q"]);
  const saving = c.save();
  const nextLibrary = { ...fixture(), playlists: [] };
  c.changeConnection(nextLibrary);
  release();
  await saving;
  expect(adds).toBe(0);
  expect(c.state().library).toBe(nextLibrary);
  expect(c.state().errorMessage).toBe("");
});

test("coalesced quiet library refreshes both resolve when the network fails", async () => {
  let reject!: (error: Error) => void;
  const pending = new Promise<Library>((_resolve, fail) => { reject = fail; });
  const c = controller(fixture(), { fetch: async () => pending });
  const first = c.refresh();
  const second = c.refresh(true);
  const results = Promise.allSettled([first, second]);
  reject(new Error("offline"));
  expect((await results).map((result) => result.status)).toEqual(["fulfilled", "fulfilled"]);
});

function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

test("rapid reorder, add, and remove writes preserve the newest playlist and serialize requests", async () => {
  const initial = fixture();
  const extra = { ...initial.tracks[0], id: "track_c", path: "c", fingerprint: "c", playlist_ids: [] };
  initial.tracks.push(extra);
  let remote = structuredClone(initial);
  const gate = deferred(), started = deferred();
  const writes: string[] = [];
  let reads = 0;
  const c = controller(initial, {
    reorder: async (_server, _playlist, ids) => { writes.push("reorder"); started.resolve(); await gate.promise; remote.playlists[0].track_ids = [...ids]; },
    add: async (_server, _playlist, fingerprint) => { writes.push("add"); remote.playlists[0].track_ids.push(`track_${fingerprint}`); },
    remove: async (_server, _playlist, fingerprint) => { writes.push("remove"); remote.playlists[0].track_ids = remote.playlists[0].track_ids.filter(id => id !== `track_${fingerprint}`); },
    fetch: async () => { reads++; return structuredClone(remote); }
  });
  c.reorder(0, 1);
  const adding = c.add(extra);
  c.remove(1);
  await started.promise;
  await c.refresh(true);
  expect(writes).toEqual(["reorder"]);
  expect(reads).toBe(0);
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_b", "track_c"]);
  gate.resolve();
  await Promise.all([adding, c.idle()]);
  expect(writes).toEqual(["reorder", "add", "remove"]);
  expect(remote.playlists[0].track_ids).toEqual(["track_b", "track_c"]);
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_b", "track_c"]);
  expect(reads).toBe(1);
});

test("membership saves wait for an earlier reorder so the reorder cannot restore a removed song", async () => {
  const initial = fixture(), gate = deferred(), started = deferred();
  let remote = structuredClone(initial);
  const writes: string[] = [];
  const c = controller(initial, {
    reorder: async (_server, _playlist, ids) => { writes.push("reorder"); started.resolve(); await gate.promise; remote.playlists[0].track_ids = [...ids]; },
    remove: async (_server, playlistId, fingerprint) => { writes.push("remove"); const p = remote.playlists.find(item => item.id === playlistId)!; p.track_ids = p.track_ids.filter(id => id !== `track_${fingerprint}`); },
    add: async (_server, playlistId, fingerprint) => { writes.push("add"); remote.playlists.find(item => item.id === playlistId)!.track_ids.push(`track_${fingerprint}`); },
    fetch: async () => structuredClone(remote)
  });
  c.reorder(0, 1);
  await started.promise;
  c.openMembership(["q"]);
  const saving = c.save();
  expect(writes).toEqual(["reorder"]);
  gate.resolve();
  await Promise.all([saving, c.idle()]);
  expect(writes).toEqual(["reorder", "remove", "add"]);
  expect(remote.playlists[0].track_ids).toEqual(["track_b"]);
  expect(remote.playlists[1].track_ids).toEqual(["track_a"]);
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_b"]);
});

test("a library read started before an edit cannot replace the pending optimistic order", async () => {
  const initial = fixture(), read = deferred<Library>(), readStarted = deferred(), write = deferred();
  let remote = structuredClone(initial), reads = 0;
  const c = controller(initial, {
    fetch: async () => { if (++reads === 1) { readStarted.resolve(); return read.promise; } return structuredClone(remote); },
    reorder: async (_server, _playlist, ids) => { await write.promise; remote.playlists[0].track_ids = [...ids]; }
  });
  const reading = c.refresh();
  await readStarted.promise;
  c.reorder(0, 1);
  read.resolve(structuredClone(initial));
  await reading;
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_b", "track_a"]);
  write.resolve();
  await c.idle();
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_b", "track_a"]);
});

test("a stale read finishing after a successful edit cannot roll it back when the fresh read is offline", async () => {
  const initial = fixture(), read = deferred<Library>(), readStarted = deferred();
  let reads = 0;
  const c = controller(initial, {
    fetch: async () => { if (++reads === 1) { readStarted.resolve(); return read.promise; } throw new Error("offline"); },
    reorder: async () => {}
  });
  const reading = c.refresh();
  await readStarted.promise;
  c.reorder(0, 1);
  // Let the write finish and its final reconciliation join the older read.
  await new Promise(resolve => setTimeout(resolve, 0));
  read.resolve(structuredClone(initial));
  await Promise.all([reading, c.idle()]);
  expect(c.state().library.playlists[0].track_ids).toEqual(["track_b", "track_a"]);
});

for (const change of ["changeConnection", "changeAuthentication"] as const) {
  test(`queued playlist writes stop after ${change}`, async () => {
    const initial = fixture(), gate = deferred(), started = deferred();
    let removes = 0, reads = 0;
    const c = controller(initial, {
      reorder: async () => { started.resolve(); await gate.promise; },
      remove: async () => { removes++; },
      fetch: async () => { reads++; return initial; }
    });
    c.reorder(0, 1);
    c.remove(0);
    await started.promise;
    const next = { ...fixture(), playlists: [] };
    c[change](next);
    gate.resolve();
    await c.idle();
    expect(removes).toBe(0);
    expect(reads).toBe(0);
    expect(c.state().library).toBe(next);
  });
}

test("changing servers during token refresh cannot send the new credential to the old download server", async () => {
  const response = deferred<Response>();
  const saved: string[][] = [];
  const source = `
    let syncServerUrl='https://server-a.test', syncTokenDraft='fixture-secret-a', guestMode=false;
    let downloadedFingerprints=new Set(), downloadingKeys=new Set(), errorMessage='';
    const refreshSyncStreamToken=api.refresh, trackAudioUrl=api.url, cacheDownload=api.save;
    const refreshDownloads=async()=>{};
    ${["downloadKey", "downloadSong"].map(controllerFunction).join("\n")}
    return {start:downloadSong, change(){syncServerUrl='https://server-b.test';syncTokenDraft='fixture-secret-b';api.auth(syncTokenDraft)}, pending:()=>downloadingKeys.size};
  `;
  setSyncAuthToken("fixture-secret-a");
  try {
    const c = new Function("api", new Bun.Transpiler({ loader: "ts" }).transformSync(source))({
      refresh: (server: string) => refreshSyncStreamToken(server, (async () => response.promise) as unknown as typeof fetch),
      url: trackAudioUrl, save: async (...args: string[]) => { saved.push(args); }, auth: setSyncAuthToken
    });
    const downloading = c.start({ fingerprint: "same-song" });
    c.change();
    response.resolve(new Response(JSON.stringify({ token: "fixture-stream-a", expires_at: Math.floor(Date.now() / 1000) + 900 }), { status: 201 }));
    await downloading;
    expect(saved).toEqual([]);
    expect(c.pending()).toBe(0);
  } finally { setSyncAuthToken(""); }
});
