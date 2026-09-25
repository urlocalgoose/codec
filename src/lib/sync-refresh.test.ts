import { expect, test } from "bun:test";
import { shouldReconcileSync, syncEventStreamExpired } from "./sync-refresh";

const page = await Bun.file(new URL("../routes/+page.svelte", import.meta.url).pathname).text();

function controllerFunction(name: string) {
  const start = page.search(new RegExp(`  (?:async )?function ${name}\\(`));
  if (start < 0) throw new Error(`Missing controller function ${name}`);
  return page.slice(start, page.indexOf("\n  }", start) + 4);
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

// Exercise the actual page lifecycle/network controller; no browser or audio
// mocks decide when reads occur. The clock and HTTP boundary are deterministic.
function controller(api: Record<string, (signal?: AbortSignal) => Promise<unknown>> = {}) {
  const functions = [
    "startPlaybackDevicePolling", "refreshPlaybackSyncOnForeground", "stopPlaybackDevicePolling",
    "startPlaybackEvents", "handlePlaybackEvent", "mergePlaybackDevice", "refreshPlaybackDevices",
    "refreshRemoteLibraryState", "publishPlaybackDeviceState", "refreshPlaybackDeviceList", "attachAux"
  ].map(controllerFunction).join("\n");
  const source = `
    let auxConnection = null, auxBridge = null;
    async function refreshAuxState() { counts.auxRefreshes++; }
    let auxInheritedFingerprint='',auxState=null,auxInviteSecret='',auxCode='',guestMode=false,auxInvitation=null,auxCreateOpen=false,settingsModalOpen=false;
    let playbackConnectionGeneration=0,playbackApplyGeneration=0,localPlaybackGeneration=0,pendingPlaybackCommands=0,deferredPlaybackState=null,deletePlaylistCandidate=null;
    const currentTrack=null,visualizerSampler=null;
    const savePlaybackSessionNow=()=>{},saveAuxConnection=()=>{};
    let now = 1000000, interval;
    const Date = {now:()=>now};
    let syncServerUrl = 'http://codec.test', syncServerReady = true, syncTokenDraft = 'secret', deviceId = 'web';
    let rootPath = 'loud://remote', playbackDevicePollTimer = null, playbackDeviceSaveTimer = null;
    let loading = false, bootstrapping = false, playbackReconnect = null, playbackDeviceRefresh = null, playbackReadController = null;
    const SYNC_SERVER_STORAGE_KEY = 'server';
    const readStoredValue = () => syncServerUrl;
    const hasNativeBridge = () => false;
    const loadRemoteLibrary = async () => {counts.reconnect++;if(api.reconnect)await api.reconnect();syncServerReady=true};
    const validatePlaybackSyncServer = loadRemoteLibrary;
    let playbackEventSource = null, playbackEventSourceUrl = '', playbackStateV2 = null, playbackDevices = [];
    let playbackEventActivityAt = 0, syncReadGeneration = 0, presenceEvents = false;
    let playbackDevicesEvaluatedRevision = -1, lastPublishedPlaybackDevice = '';
    let playbackRefresh = null, playbackRefreshAgain = false, lastPlaybackRefreshAt = 0, lastLibraryRefreshAt = 0;
    let pendingPlaylistWrites = 0, playlistMutationEpoch = 0;
    let remoteLibraryRefresh = null, remoteLibraryRefreshAgain = false, lastRemoteLibrary = null;
    const PLAYBACK_DEVICE_POLL_MS = 30000;
    const counts = {presence:0,devices:0,playback:0,library:0,applied:0,librariesApplied:0,reconnect:0,auxRefreshes:0};
    const streams = [];
    class EventSource {
      readyState = 0; handlers = {}; onopen; onerror;
      constructor(url) {this.url=url;streams.push(this)}
      addEventListener(type,handle) {this.handlers[type]=handle}
      open() {this.readyState=1;this.onopen?.()}
      fail() {this.readyState=0;this.onerror?.()}
      emit(type,payload) {this.handlers[type]?.({data:JSON.stringify({type,...payload})})}
      close() {this.readyState=2}
    }
    const window = {setInterval(fn) {interval=fn;return 1},clearInterval(){},clearTimeout(){}};
    const usePlaybackSync = () => syncServerReady;
    const isRemoteRoot = () => true;
    const refreshSyncStreamToken = async () => {};
    const playbackEventsV2Url = server => server+'/events?token='+syncTokenDraft;
    const writeCachedLibrary = async () => {};
    const syncLibrary = () => {counts.librariesApplied++};
    const resetPlaybackCommandQueue = () => {};
    const stopPlaybackClock = () => {};
    const resumeLocalAudioGraphAfterForeground = () => {};
    const playbackDeviceState = () => ({device_id:deviceId,updated_at:now});
    const updatePlaybackDevice = async () => {
      counts.presence++;
      await Promise.resolve();
      if (presenceEvents && playbackEventSource?.readyState === 1) playbackEventSource.emit('device',{device:{device_id:'web',updated_at:now}});
    };
    const fetchPlaybackDevices = async () => {counts.devices++;return api.devices ? api.devices() : [{device_id:'web',updated_at:now}]};
    const fetchPlaybackStateV2 = async (_server, _fetcher, signal) => {counts.playback++;return api.playback ? api.playback(signal) : {revision:1}};
    const fetchRemoteLibrary = async () => {counts.library++;return api.library ? api.library() : {tracks:[]}};
    const applyPlaybackStateV2 = async state => {counts.applied++;if(api.apply)await api.apply();playbackStateV2=state};
    ${functions}
    return {
      counts,streams,
      start:startPlaybackDevicePolling,
      foreground:refreshPlaybackSyncOnForeground,
      offlineLaunch(){syncServerReady=false},
      refreshPlayback:refreshPlaybackDevices,
      refreshLibrary:refreshRemoteLibraryState,
      enablePresenceEvents() {presenceEvents=true},
      attachAux:()=>attachAux({role:"host",session_id:"aux-session"},null),
      tick(ms=30000) {now+=ms;interval()},
      resetCounts() {for(const key of Object.keys(counts))counts[key]=0},
      changeConnection(sameServer=false) {stopPlaybackDevicePolling();if(!sameServer){syncServerUrl='http://other.test';syncTokenDraft='new-secret'}},
      state:()=>({playback:playbackStateV2,devices:playbackDevices}),
      merge:mergePlaybackDevice
    };
  `;
  return new Function("api", "shouldReconcileSync", "syncEventStreamExpired", new Bun.Transpiler({ loader: "ts" }).transformSync(source))(api, shouldReconcileSync, syncEventStreamExpired);
}

async function connected(api: Record<string, (signal?: AbortSignal) => Promise<unknown>> = {}) {
  const c = controller(api);
  c.start();
  await settle();
  c.streams[0].open();
  await settle();
  c.resetCounts();
  return c;
}

test("healthy SSE reduces one hour of routine traffic from 480 to 156 requests", async () => {
  const c = await connected();
  c.enablePresenceEvents();
  for (let interval = 0; interval < 120; interval++) {
    c.tick();
    await settle();
  }
  expect(c.counts.presence).toBe(120);
  expect(c.counts.devices).toBe(12);
  expect(c.counts.playback).toBe(12);
  expect(c.counts.library).toBe(12);
  expect(c.streams).toHaveLength(1);
  expect(c.counts.presence + c.counts.devices + c.counts.playback + c.counts.library).toBe(156);
});

test("disconnected SSE repairs immediately and keeps the 30-second fallback", async () => {
  const c = await connected();
  c.streams[0].fail();
  await settle();
  expect(c.counts.playback).toBe(1);
  for (let interval = 0; interval < 2; interval++) { c.tick(); await settle(); }
  expect(c.counts.presence).toBe(2);
  expect(c.counts.playback).toBe(3);
  expect(c.counts.devices).toBe(3);
  expect(c.counts.library).toBe(2);
});

test("an OPEN stream that stops delivering events is replaced after sixty seconds", async () => {
  const c = await connected();
  const stalled = c.streams[0];
  c.tick();
  await settle();
  expect(c.counts.playback).toBe(0);
  c.tick();
  await settle();
  expect(stalled.readyState).toBe(2);
  expect(c.streams).toHaveLength(2);
  expect(c.counts.playback).toBe(1);
  expect(c.counts.library).toBe(1);
  c.tick();
  await settle();
  expect(c.counts.playback).toBe(2);
});

test("a stream that never receives response headers is replaced while polling continues", async () => {
  const c = controller();
  c.start();
  await settle();
  const stalled = c.streams[0];
  c.tick();
  await settle();
  expect(c.streams).toHaveLength(1);
  c.tick();
  await settle();
  expect(stalled.readyState).toBe(2);
  expect(c.streams).toHaveLength(2);
  expect(c.counts.playback).toBe(3);
});

test("reconnect and foreground reconcile immediately without waiting five minutes", async () => {
  const c = await connected();
  c.streams[0].open();
  await settle();
  expect(c.counts.playback).toBe(1);
  expect(c.counts.library).toBe(1);
  c.foreground();
  await settle();
  expect(c.counts.playback).toBe(2);
  expect(c.counts.library).toBe(2);
  expect(c.counts.presence).toBe(1);
});

test("playback and library events still apply immediately between periodic reads", async () => {
  const c = await connected();
  c.streams[0].emit("playback_state", {playback_state:{revision:22}});
  c.streams[0].emit("library", {});
  await settle();
  expect(c.state().playback.revision).toBe(22);
  expect(c.counts.playback).toBe(0);
  expect(c.counts.library).toBe(1);
  expect(c.counts.librariesApplied).toBe(1);
});

test("overlapping routine refreshes reuse reads; library invalidations require one follow-up", async () => {
  const library = deferred<unknown>();
  const playback = deferred<unknown>();
  const c = controller({library:()=>library.promise,playback:()=>playback.promise});
  const reads = [c.refreshPlayback(),c.refreshPlayback(),c.refreshLibrary(false,false),c.refreshLibrary(false,false)];
  await settle();
  expect(c.counts.playback).toBe(1);
  expect(c.counts.library).toBe(1);
  reads.push(c.refreshLibrary());
  reads.push(c.refreshLibrary());
  library.resolve({tracks:[]});
  playback.resolve({revision:1});
  await Promise.all(reads);
  expect(c.counts.playback).toBe(1);
  expect(c.counts.library).toBe(2);
});

test("failed coalesced playback reads all settle quietly and can retry", async () => {
  const pending = deferred<unknown>();
  const c = controller({playback:()=>pending.promise});
  const first = c.refreshPlayback();
  const second = c.refreshPlayback();
  pending.reject(new Error("offline"));
  await Promise.all([first,second]);
  expect(c.counts.playback).toBe(1);
  await c.refreshPlayback();
  expect(c.counts.playback).toBe(2);
});

test("a failed periodic reconciliation retries on the next heartbeat even with SSE open", async () => {
  let fail = false;
  const c = await connected({playback: async () => {if (fail) throw new Error("offline");return {revision:1};}});
  c.enablePresenceEvents();
  fail = true;
  for (let interval = 0; interval < 10; interval++) { c.tick(); await settle(); }
  expect(c.counts.playback).toBe(1);
  fail = false;
  c.tick();
  await settle();
  expect(c.counts.playback).toBe(2);
  expect(c.streams).toHaveLength(1);
});

test("failed playback application does not mark reconciliation fresh", async () => {
  let fail = false;
  const c = await connected({apply: async () => {if (fail) throw new Error("media token offline");}});
  c.enablePresenceEvents();
  fail = true;
  for (let interval = 0; interval < 10; interval++) { c.tick(); await settle(); }
  expect(c.counts.playback).toBe(1);
  fail = false;
  c.tick();
  await settle();
  expect(c.counts.playback).toBe(2);
  expect(c.streams).toHaveLength(1);
});

test("failed library invalidation retries on the next heartbeat despite a recently successful read", async () => {
  let fail = false;
  const c = await connected({library: async () => {if (fail) throw new Error("offline");return {tracks:[]};}});
  c.enablePresenceEvents();
  fail = true;
  c.streams[0].emit("library", {});
  await settle();
  expect(c.counts.library).toBe(1);
  fail = false;
  c.tick();
  await settle();
  expect(c.counts.library).toBe(2);
});

test("failed invalidation follow-up invalidates freshness from its successful first read", async () => {
  const pending = deferred<unknown>();
  let burst = false, reads = 0;
  const c = await connected({library: async () => {
    if (!burst) return {tracks:[]};
    if (++reads === 1) return pending.promise;
    throw new Error("follow-up offline");
  }});
  c.enablePresenceEvents();
  burst = true;
  c.streams[0].emit("library", {});
  await settle();
  c.streams[0].emit("library", {});
  pending.resolve({tracks:[]});
  await settle();
  expect(c.counts.library).toBe(2);
  burst = false;
  c.tick();
  await settle();
  expect(c.counts.library).toBe(3);
});

test("failed foreground playback reconciliation retries despite a recently successful read", async () => {
  let fail = false;
  const c = await connected({playback: async () => {if (fail) throw new Error("offline");return {revision:1};}});
  c.enablePresenceEvents();
  fail = true;
  c.foreground();
  await settle();
  expect(c.counts.playback).toBe(1);
  fail = false;
  c.tick();
  await settle();
  expect(c.counts.playback).toBe(2);
});

test("an old connection's failed reads cannot clear the new connection's freshness", async () => {
  const oldLibrary = deferred<unknown>(), oldPlayback = deferred<unknown>();
  let reads = 0, playbackReads = 0;
  const c = controller({
    library: async () => ++reads === 1 ? oldLibrary.promise : {tracks:[]},
    playback: async () => ++playbackReads === 1 ? oldPlayback.promise : {revision:1}
  });
  const abandonedLibrary = c.refreshLibrary();
  const abandonedPlayback = c.refreshPlayback();
  await settle();
  c.changeConnection(true);
  c.start();
  await settle();
  c.streams[0].open();
  await settle();
  c.enablePresenceEvents();
  c.resetCounts();
  oldLibrary.reject(new Error("old request failed"));
  oldPlayback.reject(new Error("old request failed"));
  await Promise.all([abandonedLibrary, abandonedPlayback]);
  c.tick();
  await settle();
  expect(c.counts.library).toBe(0);
  expect(c.counts.playback).toBe(0);
});

test("forced command recovery arriving during a read gets one follow-up snapshot", async () => {
  const pending = deferred<unknown>();
  const c = controller({playback:()=>pending.promise});
  const first = c.refreshPlayback();
  const forced = c.refreshPlayback(true);
  pending.resolve({revision:1});
  await Promise.all([first,forced]);
  expect(c.counts.playback).toBe(2);
});

test("an HTTP response from the previous connection cannot replace current playback", async () => {
  const pending = deferred<unknown>();
  const c = controller({playback:()=>pending.promise});
  const first = c.refreshPlayback();
  c.changeConnection();
  pending.resolve({revision:999});
  await first;
  expect(c.state().playback).toBeNull();
  expect(c.counts.applied).toBe(0);
});

for (const sameServer of [false, true]) {
  test(`an abandoned library read cannot swallow invalidation after ${sameServer ? "same-server reconnect" : "server switch"}`, async () => {
    const old = deferred<unknown>();
    let requests = 0;
    const c = controller({library:async () => ++requests === 1 ? old.promise : {tracks:[{id:"new"}]}});
    const abandoned = c.refreshLibrary();
    await settle();
    c.changeConnection(sameServer);
    c.start();
    await settle();
    c.streams[0].open();
    await settle();
    expect(c.counts.library).toBe(2);
    expect(c.counts.librariesApplied).toBe(1);
    old.resolve({tracks:[{id:"old"}]});
    await abandoned;
    expect(c.counts.librariesApplied).toBe(1);
  });
}

test("callbacks from the previous connection cannot trigger reads or replace current state", async () => {
  const c = await connected();
  const old = c.streams[0];
  c.changeConnection();
  old.open(); old.fail(); old.emit("playback_state",{playback_state:{revision:999}}); old.emit("library",{});
  await settle();
  expect(c.counts.playback).toBe(0);
  expect(c.counts.library).toBe(0);
  expect(c.state().playback).toBeNull();
});

test("presence events expire offline devices using server time and ignore older updates", async () => {
  const c = controller();
  const devices = [{device_id:"old",updated_at:1},{device_id:"live",updated_at:250000}];
  expect(c.merge(devices,{device_id:"live",updated_at:240000})).toEqual([{device_id:"live",updated_at:250000}]);
});


test("foreground discards a suspended socket and reconciles the current revision", async () => {
  const c = await connected();
  const suspended = c.streams[0];
  c.foreground();
  await settle();
  expect(suspended.readyState).toBe(2);
  expect(c.streams).toHaveLength(2);
  expect(c.counts.playback).toBe(1);
  expect(c.counts.applied).toBe(1);
});


test("a saved offline launch reconnects once when foreground and online events arrive together", async () => {
  const reconnect = deferred<unknown>();
  const c = controller({reconnect:()=>reconnect.promise});
  c.offlineLaunch();
  c.foreground();
  c.foreground();
  expect(c.counts.reconnect).toBe(1);
  reconnect.resolve(undefined);
  await settle();
  c.foreground();
  await settle();
  expect(c.counts.reconnect).toBe(1);
  expect(c.counts.playback).toBe(1);
});

test("stalled discovery cannot block current playback or a later foreground refresh", async () => {
  const devices = deferred<unknown>();
  let revision = 1;
  const c = controller({devices:()=>devices.promise,playback:async()=>({revision})});
  await c.refreshPlayback();
  expect(c.state().playback.revision).toBe(1);
  revision = 2;
  await c.refreshPlayback(true);
  expect(c.state().playback.revision).toBe(2);
  expect(c.counts.devices).toBe(1);
  devices.resolve([{device_id:'native-iphone',updated_at:1}]);
  await settle();
  expect(c.state().devices[0].device_id).toBe('native-iphone');
});

test("a failed discovery request does not discard a successful playback snapshot", async () => {
  const c = controller({devices:async()=>{throw new Error('temporarily unavailable')},playback:async()=>({revision:42})});
  await c.refreshPlayback();
  expect(c.state().playback.revision).toBe(42);
});

test("foreground supersedes a suspended state request without waiting for its deadline", async () => {
  let calls = 0;
  let oldSignal: AbortSignal | undefined;
  const old = deferred<unknown>();
  const c = controller({playback: async signal => {
    if (++calls === 1) { oldSignal=signal; return old.promise; }
    return {revision:99};
  }});
  const suspended = c.refreshPlayback();
  await settle();
  await c.refreshPlayback(true);
  expect(oldSignal?.aborted).toBe(true);
  expect(c.state().playback.revision).toBe(99);
  old.resolve({revision:1});
  await suspended;
  expect(c.state().playback.revision).toBe(99);
});


test("Aux handoff invalidates a personal playback response already in flight", async () => {
  const response = deferred<unknown>();
  const c = controller({ playback: () => response.promise });
  const reading = c.refreshPlayback();
  await settle();
  c.attachAux();
  response.resolve({ revision: 44 });
  await reading;
  expect(c.counts.applied).toBe(0);
  expect(c.state().playback).toBe(null);
});

test("foreground and heartbeat while in Aux cannot publish owner presence", async () => {
  const c = await connected();
  c.attachAux();
  c.resetCounts();
  c.foreground();
  c.tick();
  await settle();
  expect(c.counts.presence).toBe(0);
  expect(c.counts.auxRefreshes).toBe(1);
});

test("Aux saves the personal resume position before handoff and never replaces it with listener time", () => {
  const functions = ["attachAux", "schedulePlaybackSessionSave", "savePlaybackSessionNow", "currentPlaybackTimeForSave"]
    .map(controllerFunction).join("\n");
  const source = `
    let auxConnection=null,auxBridge=null,auxInheritedFingerprint='',auxState=null,auxInviteSecret='',auxCode='',guestMode=false,auxInvitation=null,auxCreateOpen=false,settingsModalOpen=false;
    let syncReadGeneration=0,playbackConnectionGeneration=0,pendingPlaybackCommands=0,deferredPlaybackState=null,playbackApplyGeneration=0,localPlaybackGeneration=0;
    const visualizerSampler=null,resetPlaybackCommandQueue=()=>{},stopPlaybackClock=()=>{},saveAuxConnection=()=>{};
    let playbackSessionRestored=true,rootPath="personal-root",playbackSaveTimer=null,lastSavedPlaybackSession="";
    const PLAYBACK_SAVE_DELAY_MS=100,PLAYBACK_SESSION_STORAGE_KEY="personal-resume";
    const currentTrack={id:"personal-song",fingerprint:"personal-song"},queuedTracks=[],playbackSource=[currentTrack],sourcePlaylistID="personal-playlist",playHistory=[],selectedView="home",playbackIndex=0,audioDuration=300,currentTime=12;
    const audioEl={currentTime:12};
    const usePlaybackSync=()=>false,trackReference=track=>track;
    const writes=[];let pendingTimer;
    const window={setTimeout(fn){pendingTimer=fn;return 1},clearTimeout(){}};
    const writeStoredValue=(key,value)=>writes.push({key,value:JSON.parse(value)});
    ${functions}
    return {writes,schedule:schedulePlaybackSessionSave,save:savePlaybackSessionNow,
      queuedSave:()=>pendingTimer(),changeAudio:time=>audioEl.currentTime=time,
      attach:()=>attachAux({role:"guest",session_id:"aux-session"},null)};
  `;
  const c = new Function(new Bun.Transpiler({loader:"ts"}).transformSync(source))();
  c.schedule();
  c.attach();
  c.changeAudio(177);
  c.queuedSave(); // A timer already delivered before cancellation must also be inert.
  c.save(); // Visibility/unload calls the immediate save path.
  c.schedule();
  expect(c.writes).toHaveLength(1);
  expect(c.writes[0].value.current_track.fingerprint).toBe("personal-song");
  expect(c.writes[0].value.current_time).toBe(12);
});
