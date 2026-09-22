import { expect, test } from "bun:test";
import type { Library, Playlist, Track } from "./types";
import { refreshSyncStreamToken, setSyncAuthToken, trackAudioUrl } from "./sync";
import { abortable } from "./abortable";
import type { DownloadOptions } from "./web-downloads";

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
  const functions = ["createPlaylistFromLibrary", "commitPlaylistRename", "savePlaylistMemberships", "closePlaylistMembershipModal", "applyLocalPlaylistMemberships", "playlistSelectionForTrack", "refreshRemoteLibraryState", "enqueuePlaylistWrite", "movePlaylistSong", "removePlaylistSong", "addPlaylistSong", "deleteUserPlaylist"].map(controllerFunction).join("\n");
  const keyHandler = page.slice(page.indexOf("    const keyHandler ="), page.indexOf('    document.addEventListener("keydown", keyHandler)'));
  const source = `
    let library = initial, lastRemoteLibrary = initial, remoteLibraryRefresh = null, remoteLibraryRefreshAgain = false;
    let lastLibraryRefreshAt = 0, syncReadGeneration = 0;
    let rootPath = initial.root_path, syncServerUrl = 'http://codec.test', syncTokenDraft = 'secret', syncServerReady = true;
    let newPlaylistTitle = '', newPlaylistTrack = null, newPlaylistOpen = true, creatingPlaylist = false, createPlaylistError = '', guestMode = false;
    let selectedPlaylist = initial.playlists[0], selectedView = selectedPlaylist.id, editingPlaylistId = selectedPlaylist.id;
    let playlistNameDraft = '', renamingPlaylist = false, errorMessage = '';
    let playlistModalTrack = null, playlistModalSelectionIds = [], savingPlaylistMemberships = false;
    let mobileLayout = true;
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
    const deleteRemotePlaylist = async (...args) => api.delete(...args);
    const setRemotePlaylistTracks = async (...args) => api.reorder(...args);
    const setTrackLiked = async (...args) => api.like(...args);
    const invoke = async () => {throw new Error('Browser attempted a native command')};
    const loadLibrary = invoke;
    function syncLibrary(next) {library=next;selectedPlaylist=library.playlists.find(item=>item.id===selectedView);visibleTracks=(selectedPlaylist?.track_ids ?? []).map(id=>library.tracks.find(track=>track.id===id)).filter(Boolean)}
    function selectView(view) {selectedView=view;selectedPlaylist=library.playlists.find(item=>item.id===view)}
    function cancelPlaylistRename() {editingPlaylistId='';playlistNameDraft=''}
    ${functions}
    ${keyHandler}
    return {
      refresh: refreshRemoteLibraryState,
      create(name, track=null) {newPlaylistTitle=name;newPlaylistTrack=track;return createPlaylistFromLibrary()},
      rename(name) {playlistNameDraft=name;return commitPlaylistRename()},
      openMembership(ids) {playlistModalTrack=library.tracks[0];playlistModalSelectionIds=ids},
      save: savePlaylistMemberships,
      reorder: movePlaylistSong,
      remove: removePlaylistSong,
      add: addPlaylistSong,
      delete: deleteUserPlaylist,
      idle: () => playlistWriteTail,
      changeConnection(next) {syncReadGeneration++;syncServerUrl='http://new.test';syncTokenDraft='new';syncLibrary(next)},
      changeAuthentication(next) {syncReadGeneration++;syncTokenDraft='new';syncLibrary(next)},
      restoreConnection(next) {syncReadGeneration++;syncServerUrl='http://codec.test';syncTokenDraft='secret';syncLibrary(next)},
      setGuest(value) {guestMode=value},
      select: selectView,
      escapeMembership({mobile=true,nested=false}={}) {
        mobileLayout=mobile;
        const event={key:'Escape',defaultPrevented:false,preventDefault(){this.defaultPrevented=true},
          target:{tagName:'INPUT',closest(selector){return selector==='.native-membership-sheet'&&!nested ? {} : null}}};
        keyHandler(event);
        return event.defaultPrevented;
      },
      state: () => ({library, selectedView, newPlaylistOpen, createPlaylistError, errorMessage, savingPlaylistMemberships, playlistModalTrack, playlistModalSelectionIds})
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

test("mobile Escape commits the same staged memberships as Done or sheet dismissal", async () => {
  const initial = fixture();
  const writes: string[] = [];
  const c = controller(initial, {
    add: async (_server, playlist, fingerprint) => { writes.push(`add:${playlist}:${fingerprint}`); },
    remove: async (_server, playlist, fingerprint) => { writes.push(`remove:${playlist}:${fingerprint}`); },
    fetch: async () => { throw new Error("offline"); }
  });
  c.openMembership(["q"]);
  expect(c.escapeMembership()).toBe(true);
  expect(c.state().playlistModalTrack).toBeNull();
  await c.idle();
  expect(writes).toEqual(["remove:p:a", "add:q:a"]);
  expect(c.state().library.tracks[0].playlist_ids).toEqual(["q"]);
});

test("membership Escape preserves desktop cancellation and leaves a nested mobile dialog alone", async () => {
  const initial = fixture();
  let writes = 0;
  const api = { add: async () => { writes++; }, remove: async () => { writes++; }, fetch: async () => initial };
  const mobile = controller(initial, api);
  mobile.openMembership(["q"]);
  expect(mobile.escapeMembership({ nested: true })).toBe(false);
  expect(mobile.state().playlistModalTrack).toBe(initial.tracks[0]);
  expect(mobile.state().playlistModalSelectionIds).toEqual(["q"]);
  const desktop = controller(initial, api);
  desktop.openMembership(["q"]);
  expect(desktop.escapeMembership({ mobile: false })).toBe(true);
  expect(desktop.state().playlistModalTrack).toBeNull();
  await Promise.all([mobile.idle(), desktop.idle()]);
  expect(writes).toBe(0);
  expect(desktop.state().library).toBe(initial);
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

test("deleting a playlist preserves its songs, other memberships, and a same-named playlist when refresh is offline", async () => {
  const initial = fixture();
  initial.playlists[1].name = initial.playlists[0].name;
  initial.playlists[1].track_ids = ["track_a"];
  initial.playlists[2].track_ids = ["track_a"];
  initial.tracks[0] = { ...initial.tracks[0], playlist_ids: ["p", "q", "liked"], is_liked: true };
  const calls: string[] = [];
  const c = controller(initial, {
    delete: async (_server, id) => { calls.push(id); },
    fetch: async () => { throw new Error("offline"); }
  });
  await c.delete(initial.playlists[0]);
  expect(calls).toEqual(["p"]);
  expect(c.state().library.playlists).toEqual(initial.playlists.slice(1));
  expect(c.state().library.tracks).toEqual([
    { ...initial.tracks[0], playlist_ids: ["q", "liked"] },
    { ...initial.tracks[1], playlist_ids: [] }
  ]);
  expect(c.state().selectedView).toBe("library");
});

test("playlist deletion waits for an earlier reorder and reconciles only after both writes", async () => {
  const initial = fixture(), gate = deferred(), started = deferred();
  let remote = structuredClone(initial), reads = 0;
  const writes: string[] = [];
  const c = controller(initial, {
    reorder: async (_server, id, ids) => {
      writes.push(`reorder:${id}`); started.resolve(); await gate.promise;
      remote.playlists.find(playlist => playlist.id === id)!.track_ids = [...ids];
    },
    delete: async (_server, id) => {
      writes.push(`delete:${id}`);
      remote = { ...remote, playlists: remote.playlists.filter(playlist => playlist.id !== id),
        tracks: remote.tracks.map(track => ({ ...track, playlist_ids: track.playlist_ids.filter(member => member !== id) })) };
    },
    fetch: async () => { reads++; return structuredClone(remote); }
  });
  c.reorder(0, 1);
  await started.promise;
  const deleting = c.delete(initial.playlists[0]);
  await c.refresh(true);
  expect(writes).toEqual(["reorder:p"]);
  expect(reads).toBe(0);
  expect(c.state().library.playlists.some((playlist: Playlist) => playlist.id === "p")).toBe(true);
  gate.resolve();
  await deleting;
  expect(writes).toEqual(["reorder:p", "delete:p"]);
  expect(reads).toBe(1);
  expect(c.state().library).toEqual(remote);
  expect(c.state().library.tracks.map((track: Track) => track.id)).toEqual(["track_a", "track_b"]);
});

test("a failed playlist deletion rejects for the dialog and leaves the playlist and view intact", async () => {
  const initial = fixture();
  const c = controller(initial, {
    delete: async () => { throw new Error("Could not delete playlist (403)"); },
    fetch: async () => initial
  });
  await expect(c.delete(initial.playlists[0])).rejects.toThrow("Could not delete playlist (403)");
  expect(c.state().library).toBe(initial);
  expect(c.state().selectedView).toBe("p");
  expect(c.state().errorMessage).toBe("Could not delete playlist (403)");
});

for (const change of ["changeConnection", "changeAuthentication"] as const) {
  test(`queued playlist deletion is cancelled after ${change}`, async () => {
    const initial = fixture(), gate = deferred(), started = deferred();
    let deletes = 0, reads = 0;
    const c = controller(initial, {
      reorder: async () => { started.resolve(); await gate.promise; },
      delete: async () => { deletes++; },
      fetch: async () => { reads++; return initial; }
    });
    c.reorder(0, 1);
    await started.promise;
    const deleting = c.delete(initial.playlists[0]);
    // The new connection deliberately has the same playlist IDs.
    const next = fixture();
    c[change](next);
    gate.resolve();
    await deleting;
    expect(deletes).toBe(0);
    expect(reads).toBe(0);
    expect(c.state().library).toBe(next);
    expect(c.state().selectedView).toBe("p");
  });

  test(`an in-flight playlist deletion cannot alter the next library after ${change}`, async () => {
    const initial = fixture(), gate = deferred(), started = deferred();
    let reads = 0;
    const c = controller(initial, {
      delete: async () => { started.resolve(); await gate.promise; },
      fetch: async () => { reads++; return initial; }
    });
    const deleting = c.delete(initial.playlists[0]);
    await started.promise;
    const next = fixture();
    c[change](next);
    gate.resolve();
    await deleting;
    expect(reads).toBe(0);
    expect(c.state().library).toBe(next);
    expect(c.state().selectedView).toBe("p");
  });
}

test("deleting from Library leaves that view selected and rejects liked, missing, local, and guest targets", async () => {
  const initial = fixture();
  let deletes = 0;
  const api = { delete: async () => { deletes++; }, fetch: async () => { throw new Error("offline"); } };
  const c = controller(initial, api);
  c.select("library");
  await expect(c.delete(initial.playlists[2])).rejects.toThrow("no longer available");
  await expect(c.delete({ ...initial.playlists[0], id: "missing" })).rejects.toThrow("no longer available");
  c.setGuest(true);
  await expect(c.delete(initial.playlists[0])).rejects.toThrow("no longer available");
  const local = controller({ ...initial, root_path: "/music" }, api);
  await expect(local.delete(initial.playlists[0])).rejects.toThrow("no longer available");
  expect(deletes).toBe(0);
  c.setGuest(false);
  await c.delete(initial.playlists[0]);
  expect(deletes).toBe(1);
  expect(c.state().selectedView).toBe("library");
});

for (const phase of ["queued", "in flight"] as const) {
  test(`a ${phase} deletion stays stale after switching A → B → A with the same server and token`, async () => {
    const initial = fixture(), gate = deferred(), started = deferred();
    let deletes = 0, reads = 0;
    const c = controller(initial, {
      reorder: async () => { started.resolve(); await gate.promise; },
      delete: async () => {
        deletes++;
        if (phase === "in flight") { started.resolve(); await gate.promise; }
      },
      fetch: async () => { reads++; return initial; }
    });
    if (phase === "queued") {
      c.reorder(0, 1);
      await started.promise;
    }
    const deleting = c.delete(initial.playlists[0]);
    if (phase === "in flight") await started.promise;
    c.changeConnection(fixture());
    const latest = fixture();
    latest.playlists[0].name = "Updated while away";
    c.restoreConnection(latest);
    gate.resolve();
    await deleting;
    expect(deletes).toBe(phase === "queued" ? 0 : 1);
    expect(reads).toBe(0);
    expect(c.state().library).toBe(latest);
    expect(c.state().selectedView).toBe("p");
  });
}

type DownloadAPI = {
  refresh?: (server: string) => Promise<void>;
  url?: (server: string, fingerprint: string) => string;
  save?: (server: string, fingerprint: string, url: string, options: DownloadOptions) => Promise<void>;
  list?: (server: string) => Promise<Set<string>>;
  remove?: (server: string, fingerprint: string) => Promise<void>;
  auth?: (token: string) => void;
};

function downloadsController(api: DownloadAPI = {}, saved: string[] = []) {
  const functions = ["downloadKey", "showDownloadProgress", "startDownloads", "downloadSong", "refreshDownloads", "removeDownloadedSong"].map(controllerFunction).join("\n");
  // Exercise the same Svelte connection guard as the mounted controller, rather
  // than recreating its cancellation policy inside the fixture.
  const guardStart = page.indexOf("  $: if (downloadRun &&");
  if (guardStart < 0) throw new Error("Missing download connection guard");
  const guard = page.slice(guardStart, page.indexOf("\n  }", guardStart) + 4);
  const source = `
    let syncServerUrl='https://server-a.test', syncTokenDraft='fixture-secret-a', guestMode=false;
    let downloadedFingerprints=new Set(saved), downloadingKeys=new Set(), downloadEpoch=0, downloadRun=null;
    let status=null;
    const downloadStatus={set(next){status=next}};
    const refreshSyncStreamToken=api.refresh ?? (async()=>{});
    const trackAudioUrl=api.url ?? ((server, fingerprint)=>server+'/audio/'+fingerprint);
    const cacheDownload=api.save ?? (async()=>{});
    const listDownloaded=api.list ?? (async()=>new Set());
    const deleteDownload=api.remove ?? (async()=>{});
    ${functions}
    function connectionChanged() { ${guard} }
    return {
      start:downloadSong, batch:startDownloads, refresh:refreshDownloads, remove:removeDownloadedSong,
      cancel(){status?.cancel?.()},
      change(server, token, nextSaved=[]) {
        syncServerUrl=server;syncTokenDraft=token;downloadedFingerprints=new Set(nextSaved);
        api.auth?.(token);connectionChanged();
      },
      guest(){guestMode=true;connectionChanged()},
      state:()=>({downloaded:[...downloadedFingerprints],pending:[...downloadingKeys],status,running:Boolean(downloadRun)})
    };
  `;
  return new Function("api", "saved", "abortable", new Bun.Transpiler({ loader: "ts" }).transformSync(source))(api, saved, abortable);
}

function downloadTrack(fingerprint: string, direct = true): Track {
  return { ...fixture().tracks[0], id: `track_${fingerprint}`, fingerprint,
    title: `Song ${fingerprint}`, media_url: direct ? `https://server-a.test/audio/${fingerprint}` : undefined };
}

const settleDownloads = () => new Promise<void>(resolve => setTimeout(resolve, 0));

test("downloads run at most two transfers, append new requests, and skip duplicate or already saved songs", async () => {
  const fingerprints = ["a", "b", "c", "d", "e"];
  const gates = new Map(fingerprints.map(id => [id, deferred()]));
  const requests: string[] = [];
  let active = 0, maximumActive = 0;
  const c = downloadsController({ save: async (_server, fingerprint, _url, options) => {
    requests.push(fingerprint);
    active++; maximumActive = Math.max(maximumActive, active);
    try {
      options.onProgress?.(5, 10);
      await gates.get(fingerprint)!.promise;
    } finally { active--; }
  } });
  const pending = c.batch(["a", "b", "c", "d", "a"].map(id => downloadTrack(id)));
  expect(requests).toEqual(["a", "b"]);
  expect(c.state().pending).toHaveLength(4);
  await c.batch([downloadTrack("b"), downloadTrack("e")]);
  expect(requests).toEqual(["a", "b"]);
  expect(c.state().pending).toHaveLength(5);
  expect(c.state().status.progress).toBeCloseTo(1 / 5);
  for (const fingerprint of fingerprints) { gates.get(fingerprint)!.resolve(); await settleDownloads(); }
  await pending;
  expect(maximumActive).toBe(2);
  expect(requests).toEqual(fingerprints);
  expect(c.state().downloaded.sort()).toEqual(fingerprints);
  expect(c.state().pending).toEqual([]);
  expect(c.state().running).toBe(false);
  expect(c.state().status).toMatchObject({ state: "done", message: "5 songs downloaded" });
  await c.batch(fingerprints.map(id => downloadTrack(id)));
  expect(requests).toEqual(fingerprints);
});

test("cancel during shared token refresh settles promptly and retry owns only its new pending rows", async () => {
  const token = deferred();
  const saved: string[] = [];
  const c = downloadsController({ refresh: () => token.promise, save: async (_server, fingerprint) => { saved.push(fingerprint); } });
  const old = c.batch([downloadTrack("a", false), downloadTrack("b", false)]);
  c.cancel();
  let oldSettled = false;
  void old.then(() => { oldSettled = true; });
  const retry = c.start(downloadTrack("retry", false));
  try {
    expect(c.state().pending).toEqual(["https://server-a.test\u0000retry"]);
    await settleDownloads();
    expect(oldSettled).toBe(true);
    expect(c.state().status).toMatchObject({ state: "downloading", detail: "Song retry" });
    expect(saved).toEqual([]);
  } finally {
    token.resolve();
    await Promise.all([old, retry]);
  }
  expect(saved).toEqual(["retry"]);
  expect(c.state().downloaded).toEqual(["retry"]);
  expect(c.state().pending).toEqual([]);
  expect(c.state().status).toMatchObject({ state: "done", message: "Song downloaded" });
});

for (const nextServer of ["https://server-b.test", "https://server-a.test"]) {
  test(`changing ${nextServer.includes("server-b") ? "server" : "authentication"} during token refresh never sends the new credential to the old download`, async () => {
    const response = deferred<Response>();
    const saves: string[][] = [], urls: string[][] = [], refreshes: Promise<void>[] = [];
    setSyncAuthToken("fixture-secret-a");
    const c = downloadsController({
      refresh: (server) => {
        const refresh = refreshSyncStreamToken(server, (async () => response.promise) as unknown as typeof fetch);
        refreshes.push(refresh); return refresh;
      },
      url: (server, fingerprint) => { urls.push([server, fingerprint]); return trackAudioUrl(server, fingerprint); },
      save: async (server, fingerprint, url) => { saves.push([server, fingerprint, url]); }, auth: setSyncAuthToken
    });
    try {
      const pending = c.start(downloadTrack("same-song", false));
      c.change(nextServer, "fixture-secret-b", ["new-connection-download"]);
      await pending;
      expect(saves).toEqual([]);
      expect(urls).toEqual([]);
      expect(c.state().downloaded).toEqual(["new-connection-download"]);
      expect(c.state().pending).toEqual([]);
      expect(c.state().status).toBeNull();
    } finally {
      response.resolve(new Response(JSON.stringify({ token: "fixture-stream-a", expires_at: Math.floor(Date.now() / 1000) + 900 }), { status: 201 }));
      await Promise.all(refreshes);
      setSyncAuthToken("");
    }
  });
}

test("an old storage operation finishing after connection change cannot alter new membership or feedback", async () => {
  const oldStorage = deferred(), newStorage = deferred();
  const c = downloadsController({ save: async (_server, fingerprint) => fingerprint === "old" ? oldStorage.promise : newStorage.promise });
  const old = c.start(downloadTrack("old"));
  c.change("https://server-b.test", "fixture-secret-b", ["existing"]);
  const current = c.start(downloadTrack("new"));
  oldStorage.resolve();
  await old;
  expect(c.state().downloaded).toEqual(["existing"]);
  expect(c.state().pending).toEqual(["https://server-b.test\u0000new"]);
  expect(c.state().status).toMatchObject({ state: "downloading", detail: "Song new" });
  newStorage.resolve();
  await current;
  expect(c.state().downloaded).toEqual(["existing", "new"]);
  expect(c.state().pending).toEqual([]);
});

test("a cache listing started before a completed download cannot erase the new saved membership", async () => {
  const listing = deferred<Set<string>>();
  const c = downloadsController({ list: () => listing.promise });
  const refresh = c.refresh("https://server-a.test");
  await c.start(downloadTrack("new"));
  listing.resolve(new Set());
  await refresh;
  expect(c.state().downloaded).toEqual(["new"]);
  expect(c.state().status).toMatchObject({ state: "done" });
});

test("one failed transfer stops the batch, clears pending rows, and reports the storage error", async () => {
  const pending = deferred();
  const requests: string[] = [];
  const c = downloadsController({ save: async (_server, fingerprint, _url, options) => {
    requests.push(fingerprint);
    if (fingerprint === "b") throw new Error("Not enough browser storage.");
    return abortable(pending.promise, options.signal!);
  } }, ["saved-earlier"]);
  await c.batch(["a", "b", "c", "d"].map(id => downloadTrack(id)));
  expect(requests).toEqual(["a", "b"]);
  expect(c.state().pending).toEqual([]);
  expect(c.state().downloaded).toEqual(["saved-earlier"]);
  expect(c.state().status).toMatchObject({ state: "error", message: "Download stopped", detail: "Not enough browser storage." });
  pending.resolve();
});

test("entering guest mode cancels pending downloads without saving or leaving feedback", async () => {
  const token = deferred();
  let saves = 0;
  const c = downloadsController({ refresh: () => token.promise, save: async () => { saves++; } });
  const pending = c.start(downloadTrack("private", false));
  c.guest();
  await pending;
  token.resolve();
  expect(saves).toBe(0);
  expect(c.state().pending).toEqual([]);
  expect(c.state().status).toBeNull();
  await c.start(downloadTrack("another"));
  expect(saves).toBe(0);
});

test("removing an offline song updates membership, but a stale removal cannot clear the next server's membership", async () => {
  const gate = deferred();
  const c = downloadsController({ remove: () => gate.promise }, ["song"]);
  const removing = c.remove(downloadTrack("song"));
  c.change("https://server-b.test", "fixture-secret-b", ["song"]);
  gate.resolve();
  await removing;
  expect(c.state().downloaded).toEqual(["song"]);
  expect(c.state().status).toBeNull();
  await c.remove(downloadTrack("song"));
  expect(c.state().downloaded).toEqual([]);
  expect(c.state().status).toMatchObject({ state: "done", message: "Download removed" });
});
