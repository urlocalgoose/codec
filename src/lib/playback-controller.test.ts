import { expect, test } from "bun:test";
import { derivedPlaybackPosition, type PlaybackStateV2 } from "./sync";
import { playbackPositionChanged } from "./playback-continuity";

const page = await Bun.file(new URL("../routes/+page.svelte", import.meta.url).pathname).text();

// Run the actual page controller with deterministic audio and network boundaries.
function controllerFunction(name: string) {
  const start = page.search(new RegExp(`  (?:async )?function ${name}\\(`));
  if (start < 0) throw new Error(`Missing controller function ${name}`);
  return page.slice(start, page.indexOf("\n  }", start) + 4);
}

function controller() {
  const functions = ["applyPlaybackStateV2", "syncLocalAudioToPlaybackState", "audioSourceIdentity", "publishPlaybackDeviceState", "startPlaybackDevicePolling", "selectedPlaybackTargetDeviceId", "currentPlaybackTimeForSave", "usePlaybackSync", "playbackDeviceChoices", "isActiveSyncDevice", "syncDuration", "handleAudioError", "handleAudioPlay", "handleAudioPause", "playLocalAudio", "pauseLocalAudio", "publishLocalMediaState", "handleSystemPlayback", "canControlLocalMedia", "resumeLocalAudioGraphAfterForeground", "refreshPlaybackSyncOnForeground", "attachAux", "prepareAuxAudio"].map(controllerFunction).join("\n");
  const source = `
    let auxConnection = null, auxBridge = null;
    async function refreshAuxState() {}
    let auxInheritedFingerprint='',auxState=null,auxInviteSecret='',auxCode='',guestMode=false,auxInvitation=null,auxCreateOpen=false,settingsModalOpen=false;
    let syncReadGeneration=0,playbackConnectionGeneration=0;
    const visualizerSampler=null;
    const savePlaybackSessionNow=()=>{},resetPlaybackCommandQueue=()=>{},saveAuxConnection=()=>{};
    let playbackStateV2 = null, pendingPlaybackCommands = 0, deferredPlaybackState = null;
    let playbackApplyGeneration = 0, localPlaybackGeneration = 0, playbackClockOffsetMs = 0;
    let currentTrack = null, currentTime = 0, isPlaying = false, volume = 1, audioDuration = 0, errorMessage = "";
    let audioGraphContext = null, visualizerAnalyser = null;
    const playbackAudioSession = {begin(){},release(){counts.graphReleases++},isInterrupted(){return false}};
    let expectedAudioPlayEvents = 0, expectedAudioPauseEvents = 0;
    const commands = [];
    const navigator = {userActivation:{hasBeenActive:false}};
    const document = {hidden:false};
    let selectedPlaybackDeviceId = 'web', deviceId = 'web', syncServerUrl = 'http://codec.test', syncServerReady = true;
    let playbackDevices = [{device_id:'web'}], applyingRemotePlayback = false;
    let loadedSource = '', loadedTrackId = '', lastPublishedPlaybackDevice = '', playbackDevicePollTimer = null;
    let playbackEventSource = null, playbackEventActivityAt = 0, lastPlaybackRefreshAt = 0, lastLibraryRefreshAt = 0;
    const syncEventStreamExpired = () => false;
    const shouldReconcileSync = () => true;
    const SYNC_SELECTED_DEVICE_STORAGE_KEY = '', VOLUME_STORAGE_KEY = '', PLAYBACK_DEVICE_POLL_MS = 30000;
    const track = {id:'song',fingerprint:'song',duration_seconds:300};
    const library = {tracks:[track]};
    const counts = {loads:0,plays:0,pauses:0,presence:0,seeks:0,commands:0,graphSuspends:0,graphResumes:0,graphReleases:0};
    let token = 'first', metadata = Promise.resolve(), playCompletion = Promise.resolve(), refreshCompletion = Promise.resolve(), interval, rejectPlay = false;
    const window = {setInterval(fn) {interval=fn;return 1}};
    let audioTime = 0;
    const audioEl = {error:null,ended:false,readyState:4,get currentTime(){return audioTime},set currentTime(value){counts.seeks++;audioTime=value},paused:true,async play(){counts.plays++;if(rejectPlay)throw new DOMException('User gesture required','NotAllowedError');this.paused=false;return playCompletion},pause(){counts.pauses++;this.paused=true}};
    function findTrackByReference(_library,ref){return ref.id===track.id?track:null}
    function clampPlaybackTime(time){return time}
    function writeStoredValue(){}
    function applyPlaybackContextV2(){}
    function stopPlaybackClock(){}
    function updatePlaybackClock(){}
    function schedulePlaybackDeviceUpdate(){}
    function applyPendingSeek(){}
    function mediaErrorMessage(message){return message}
    function activateThisPlaybackDevice(){counts.commands++}
    function ensureAnalyser(){return null}
    function currentSyncedPlaybackPosition(){return derivedPlaybackPosition(playbackStateV2,Date.now(),playbackClockOffsetMs)}
    async function playbackUrlForTrack(){return 'http://codec.test/song?access_token='+token}
    function loadAudioSource(source,_position,trackId){loadedSource=source;loadedTrackId=trackId;counts.loads++}
    function waitForAudioMetadata(){return metadata}
    function playbackDeviceState(){return {device_id:'web',is_playing:true,position_seconds:0,updated_at:Date.now()}}
    async function updatePlaybackDevice(){counts.presence++}
    async function refreshPlaybackDevices(){return refreshCompletion}
    async function refreshRemoteLibraryState(){}
    async function startPlaybackEvents(){}
    async function sendPlaybackCommand(kind,options){
      counts.commands++;commands.push({kind,...options});
      playbackApplyGeneration++;localPlaybackGeneration++;applyingRemotePlayback=false;
      return {...playbackStateV2,revision:playbackStateV2.revision+1,state:kind==='play'?'playing':'paused',clock:{...playbackStateV2.clock,position_seconds:options.position_seconds}};
    }
    ${functions}
    return {
      async apply(value, force){
        await applyPlaybackStateV2(value, force);
        // The real browser delivers queued events; this harness flushes them
        // explicitly, including events delivered after the remote guard clears.
        while(expectedAudioPlayEvents) handleAudioPlay();
        while(expectedAudioPauseEvents) handleAudioPause();
      },counts,audioEl,commands,
      systemPlayback:handleSystemPlayback,
      pendingTarget:(target)=>{selectedPlaybackDeviceId=target},
      appPause:pauseLocalAudio, appPlay:playLocalAudio,
      state:()=>playbackStateV2,
      displayed:()=>({currentTrack,currentTime,isPlaying,selectedPlaybackDeviceId,audioDuration,errorMessage}),
      mediaMetadata:syncDuration, mediaError:handleAudioError,mediaPlay:handleAudioPlay,mediaPause:handleAudioPause,
      foreground:refreshPlaybackSyncOnForeground,
      target:selectedPlaybackTargetDeviceId,
      positionForCommand:currentPlaybackTimeForSave,
      choices:()=>playbackDeviceChoices(playbackDevices,deviceId,"This web browser",selectedPlaybackDeviceId),
      duration:(value)=>{track.duration_seconds=value},
      runningGraph:()=>{audioGraphContext={state:"running",suspend(){counts.graphSuspends++;this.state="suspended";return Promise.resolve()}}},
      suspendedGraph:()=>{audioGraphContext={state:"suspended",resume(){counts.graphResumes++;this.state="running";return Promise.resolve()}}},
      delayRefresh:()=>{let release;refreshCompletion=new Promise(resolve=>{release=resolve});return release},
      delayedGraph:()=>{
        let release;
        audioGraphContext={state:"running",suspend(){counts.graphSuspends++;return new Promise(resolve=>{release=()=>{this.state="suspended";resolve()}})},resume(){counts.graphResumes++;this.state="running";return Promise.resolve()}};
        return ()=>release();
      },
      refuseAutoplay:()=>{rejectPlay=true},
      delayPlay:()=>{let release;playCompletion=new Promise(resolve=>{release=resolve});return release},
      advanceAudio:(position)=>{audioTime=position},
      changeToken:()=>{token='second'},
      delayMetadata:()=>{let release;metadata=new Promise(resolve=>{release=resolve});return release},
      attachAux:()=>attachAux({role:"host",session_id:"aux-session"},null),
      startPolling:startPlaybackDevicePolling,
      poll:()=>interval()
    };
  `;
  return new Function("derivedPlaybackPosition", "playbackPositionChanged", new Bun.Transpiler({ loader: "ts" }).transformSync(source))(derivedPlaybackPosition, playbackPositionChanged);
}

function state(revision: number, status: "playing" | "paused" = "playing", device = "web"): PlaybackStateV2 {
  return {
    schema: "loud.playback.v2", revision, active_device_id: device, state: status,
    track: { id: "song", path: "song", fingerprint: "song" },
    context: { playback_source: [], playback_index: 0, queued_tracks: [], play_history: [], shuffle: false, repeat: "off" },
    clock: { position_seconds: 0, started_at_ms: null, stopped_at_ms: null, updated_at_ms: Date.now() },
    volume: 1, server_time_ms: Date.now()
  };
}

test("a forced old response cannot undo a newer revision", async () => {
  const c = controller();
  await c.apply(state(12));
  await c.apply(state(11, "paused"), true);
  expect(c.state().revision).toBe(12);
  expect(c.audioEl.paused).toBe(false);
});

test("rotating a token does not reload the same audio for a pause", async () => {
  const c = controller();
  await c.apply(state(1));
  c.changeToken();
  await c.apply(state(2, "paused"));
  expect(c.counts.loads).toBe(1);
  expect(c.audioEl.paused).toBe(true);
});

test("a transfer supersedes an in-flight metadata load", async () => {
  const c = controller();
  const release = c.delayMetadata();
  const loading = c.apply(state(1));
  await Promise.resolve();
  expect(c.counts.loads).toBe(1);
  await c.apply(state(2, "playing", "phone"));
  release();
  await loading;
  expect(c.counts.plays).toBe(0);
  expect(c.audioEl.paused).toBe(true);
});

test("a pause supersedes an in-flight metadata load", async () => {
  const c = controller();
  const release = c.delayMetadata();
  const loading = c.apply(state(1));
  await Promise.resolve();
  await c.apply(state(2, "paused"));
  release();
  await loading;
  expect(c.counts.plays).toBe(0);
  expect(c.audioEl.paused).toBe(true);
});

test("unchanged playback still publishes every scheduled heartbeat", async () => {
  const c = controller();
  c.startPolling();
  await Promise.resolve();
  c.poll();
  await Promise.resolve();
  c.poll();
  await Promise.resolve();
  expect(c.counts.presence).toBe(3);
});

test("forced same-revision reconciliation preserves buffered local playback", async () => {
  const c = controller();
  const playing = state(1);
  playing.clock = { ...playing.clock, position_seconds: 20, started_at_ms: Date.now(), updated_at_ms: Date.now() };
  await c.apply(playing);
  c.advanceAudio(17); // The real speaker started later than the server clock.
  await c.apply({ ...playing, server_time_ms: Date.now() }, true);
  expect(c.audioEl.currentTime).toBe(17);
  expect(c.counts.seeks).toBe(0);
  expect(c.counts.loads).toBe(1);
  expect(c.counts.plays).toBe(1);
});

test("queue-only clock rebases do not skip buffered audio", async () => {
  const c = controller();
  const now = Date.now();
  const playing = state(1);
  playing.clock = { ...playing.clock, position_seconds: 20, started_at_ms: now - 10_000, updated_at_ms: now - 10_000 };
  await c.apply(playing);
  c.advanceAudio(27);
  const queued = { ...playing, revision: 2, server_time_ms: now, clock: { ...playing.clock, position_seconds: 30, started_at_ms: now, updated_at_ms: now } };
  await c.apply(queued);
  expect(c.audioEl.currentTime).toBe(27);
  expect(c.counts.seeks).toBe(0);
  expect(c.counts.plays).toBe(1);
});

test("a real remote seek still moves local audio", async () => {
  const c = controller();
  const playing = state(1);
  playing.clock = { ...playing.clock, position_seconds: 20, started_at_ms: Date.now(), updated_at_ms: Date.now() };
  await c.apply(playing);
  c.advanceAudio(17);
  await c.apply({ ...playing, revision: 2, clock: { ...playing.clock, position_seconds: 90 } });
  expect(c.audioEl.currentTime).toBeGreaterThanOrEqual(90);
  expect(c.counts.seeks).toBe(1);
});

test("queue edits build on a pending remote play context before its acknowledgement", async () => {
  const sent: Array<{ kind: string; context: PlaybackStateV2["context"] }> = [];
  const replies: Array<(state: PlaybackStateV2) => void> = [];
  const functions = ["sendPlaybackCommand", "applyPlaybackContextV2", "playbackContextSnapshot"].map(controllerFunction).join("\n");
  const source = `
    let auxConnection = null, auxBridge = null;
    async function refreshAuxState() {}
    let syncServerUrl = 'http://codec.test', deviceId = 'web', syncServerReady = true;
    let playbackConnectionGeneration = 0, playbackApplyGeneration = 0, localPlaybackGeneration = 0;
    let applyingRemotePlayback = false, pendingPlaybackCommands = 0, deferredPlaybackState = null;
    let playbackStateV2 = {revision: 10}, volume = 1;
    let playbackSource = [], sourcePlaylistID = null, playbackIndex = 0, queuedTracks = [], playHistory = [], shuffle = false, repeatMode = 'off';
    const library = {}, SHUFFLE_STORAGE_KEY = '', REPEAT_STORAGE_KEY = '';
    const tracksFromReferences = (_library, references) => [...references];
    const trackReference = track => track;
    const writeStoredValue = () => {};
    const createPlaybackCommandId = kind => kind;
    const selectedPlaybackTargetDeviceId = () => 'phone';
    const refreshPlaybackDevices = () => {};
    const applyPlaybackStateV2 = () => {};
    ${functions}
    return {
      send: sendPlaybackCommand,
      addToQueue(track) {
        queuedTracks = [...queuedTracks, track];
        return sendPlaybackCommand('set_queue', {context: playbackContextSnapshot()});
      }
    };
  `;
  const transport = (_server: string, command: typeof sent[number]) => {
    sent.push(command);
    return new Promise<PlaybackStateV2>((resolve) => replies.push(resolve));
  };
  const c = new Function("sendPlaybackCommandV2", new Bun.Transpiler({ loader: "ts" }).transformSync(source))(transport);
  const song = { id: "remote-song", path: "remote-song", fingerprint: "remote-song" };
  const added = { id: "added", path: "added", fingerprint: "added" };
  const context = { ...state(10).context, playlist_id: "started-on-phone", playback_source: [song], shuffle: true, repeat: "all" };
  const first = c.send("play", { track: song, context });
  const second = c.addToQueue(added);
  replies[0](state(11));
  replies[1](state(12));
  await Promise.all([first, second]);
  expect(sent[1].context.playlist_id).toBe("started-on-phone");
  expect(sent[1].context.playback_source).toEqual([song]);
  expect(sent[1].context.queued_tracks).toEqual([added]);
  expect(sent[1].context.shuffle).toBe(true);
  expect(sent[1].context.repeat).toBe("all");
});


test("native background playback remains playing without a discovery heartbeat", async () => {
  const c = controller();
  const playing = state(4, "playing", "native-iphone");
  playing.clock = { ...playing.clock, position_seconds: 42, started_at_ms: Date.now(), updated_at_ms: Date.now() };
  await c.apply(playing);
  expect(c.displayed().isPlaying).toBe(true);
  expect(c.displayed().currentTrack.id).toBe("song");
  expect(c.displayed().currentTime).toBeGreaterThanOrEqual(42);
  expect(c.target()).toBe("native-iphone");
  expect(c.counts.loads).toBe(0);
  expect(c.counts.plays).toBe(0);
  expect(c.counts.commands).toBe(0);
});

test("autoplay denial stays local and never writes a shared pause", async () => {
  const c = controller();
  c.refuseAutoplay();
  await c.apply(state(1));
  expect(c.displayed().isPlaying).toBe(false);
  expect(c.state().state).toBe("playing");
  expect(c.counts.commands).toBe(0);
});

test("late legacy session restore cannot overwrite a live native session", async () => {
  let release!: (value: unknown) => void;
  const pending = new Promise(resolve => { release = resolve; });
  const source = `
    let auxConnection = null, auxBridge = null;
    async function refreshAuxState() {}
    let syncServerUrl = 'http://codec.test', syncReadGeneration = 1, playbackStateV2 = null;
    const PLAYBACK_SESSION_STORAGE_KEY = '';
    let applied = 0, saved = 0;
    const validPlaybackSession = () => true;
    const readStoredValue = () => null;
    const parsePlaybackSession = () => null;
    const applyPlaybackSession = () => {applied++};
    const savePlaybackSessionNow = () => {saved++};
    ${controllerFunction("restoreRemotePlaybackSession")}
    return {restore:restoreRemotePlaybackSession,live(){playbackStateV2={revision:5}},counts:()=>({applied,saved})};
  `;
  const c = new Function("fetchLatestPlaybackSession", new Bun.Transpiler({loader:"ts"}).transformSync(source))(() => pending);
  const restoring = c.restore({root_path:"loud://fixture"});
  c.live();
  release({session:{saved_at:Date.now()}});
  await restoring;
  expect(c.counts()).toEqual({applied:0,saved:0});
});


test("remote commands use the native clock after this browser previously played audio", async () => {
  const c = controller();
  await c.apply(state(1));
  c.advanceAudio(8);
  const playing = state(2, "playing", "native-iphone");
  playing.clock = {...playing.clock,position_seconds:75,started_at_ms:Date.now(),updated_at_ms:Date.now()};
  await c.apply(playing);
  expect(c.audioEl.currentTime).toBe(8);
  expect(c.positionForCommand()).toBeGreaterThanOrEqual(75);
});


test("an owner missing from discovery remains an explicit remote device option", async () => {
  const c = controller();
  await c.apply(state(1,"playing","native-iphone"));
  expect(c.choices().find((device: { device_id: string; name: string }) => device.device_id === "native-iphone")?.name).toBe("Other device");
});

test("a long native track stays playing beyond thirty minutes without transport commands", async () => {
  const c = controller();
  c.duration(7200);
  const playing = state(1,"playing","native-iphone");
  const start = Date.now() - 31 * 60_000;
  playing.clock = {...playing.clock,started_at_ms:start,updated_at_ms:start};
  await c.apply(playing);
  expect(c.displayed().isPlaying).toBe(true);
  expect(c.target()).toBe("native-iphone");
  expect(c.displayed().currentTime).toBeGreaterThanOrEqual(31*60);
});


test("late metadata and errors from old web audio cannot change native playback", async () => {
  const c = controller();
  await c.apply(state(1));
  await c.apply(state(2,"playing","native-iphone"));
  c.audioEl.duration = 12;
  c.mediaMetadata();
  c.audioEl.error = {code:2};
  c.mediaError();
  c.mediaPause();
  expect(c.displayed().audioDuration).toBe(300);
  expect(c.displayed().errorMessage).toBe("");
  expect(c.displayed().isPlaying).toBe(true);
  expect(c.counts.commands).toBe(0);
});

test("a late local play event stops stale audio after native takes ownership", async () => {
  const c = controller();
  await c.apply(state(1));
  await c.apply(state(2,"playing","native-iphone"));
  c.audioEl.paused = false;
  c.mediaPlay();
  expect(c.audioEl.paused).toBe(true);
  expect(c.displayed().isPlaying).toBe(true);
  expect(c.target()).toBe("native-iphone");
  expect(c.counts.commands).toBe(0);
});


test("a delayed transport event does not move the remote clock backward", async () => {
  const c = controller();
  const initial = state(1, "playing", "native-iphone");
  initial.clock = {...initial.clock,position_seconds:40,started_at_ms:Date.now()-20_000,updated_at_ms:Date.now()-20_000};
  await c.apply(initial);
  const before = c.displayed().currentTime;
  const delayed = {...initial,revision:2,server_time_ms:Date.now()-5000};
  await c.apply(delayed);
  expect(c.displayed().currentTime).toBeGreaterThanOrEqual(before - 0.01);
});


test("transferring playback away suspends the browser audio graph", async () => {
  const c = controller();
  await c.apply(state(1));
  c.runningGraph();
  await c.apply(state(2,"playing","native-iphone"));
  expect(c.counts.graphSuspends).toBe(1);
  expect(c.audioEl.paused).toBe(true);
  expect(c.displayed().isPlaying).toBe(true);
});

test("a remote or paused visualizer never creates or resumes a silent audio session", () => {
  const source = `
    let auxConnection = null, auxBridge = null;
    async function refreshAuxState() {}
    let audioGraphContext = null, visualizerAnalyser = null, visualizerSampler = null;
    const playbackAudioSession = {begin(){},release(){},isInterrupted(){return false}};
    let local = false;
    const audioEl = {paused:false};
    const counts = {created:0,resumed:0};
    const usePlaybackSync = () => true, isActiveSyncDevice = () => local;
    class AudioContext {
      destination = {};
      constructor(){counts.created++}
      createMediaElementSource(){return {connect(){}}}
      createAnalyser(){return {connect(){}}}
      resume(){counts.resumed++;return Promise.resolve()}
    }
    class SpectroSampler {}
    ${controllerFunction("ensureAnalyser")}
    return {ensure:ensureAnalyser,counts,audioEl,local(){local=true}};
  `;
  const c = new Function(new Bun.Transpiler({loader:"ts"}).transformSync(source))();
  expect(c.ensure()).toBe(null);
  expect(c.counts).toEqual({created:0,resumed:0});
  c.local(); c.audioEl.paused=true;
  expect(c.ensure()).toBe(null);
  expect(c.counts).toEqual({created:0,resumed:0});
  c.audioEl.paused=false;
  expect(c.ensure()).not.toBe(null);
  expect(c.counts).toEqual({created:1,resumed:1});
});


test("a quick transfer back resumes local audio after an outstanding graph suspension", async () => {
  const c = controller();
  await c.apply(state(1));
  const release = c.delayedGraph();
  await c.apply(state(2,"playing","native-iphone"));
  await c.apply(state(3,"playing","web"));
  release();
  await Promise.resolve();
  expect(c.counts.graphResumes).toBe(1);
  expect(c.audioEl.paused).toBe(false);
});

test("an aborted foreground refresh cannot wake a graph using stale ownership", async () => {
  const c = controller();
  await c.apply(state(1));
  c.suspendedGraph();
  const release = c.delayRefresh();
  c.foreground();
  // Cancelled/superseded reads resolve without applying a state. Recovery
  // must await an actual current state, not this promise's completion.
  release();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  expect(c.counts.graphResumes).toBe(0);
  await c.apply(state(2, "playing", "phone"));
  expect(c.counts.graphResumes).toBe(0);
  expect(c.audioEl.paused).toBe(true);
});

test("a current owned playback state recovers the graph without restarting or seeking audio", async () => {
  const c = controller();
  const current = state(1);
  await c.apply(current);
  c.advanceAudio(25);
  c.suspendedGraph();
  const before = {...c.counts};
  await c.apply(current, true);
  expect(c.counts.graphResumes).toBe(1);
  expect(c.counts.plays).toBe(before.plays);
  expect(c.counts.loads).toBe(before.loads);
  expect(c.counts.seeks).toBe(before.seeks);
  expect(c.audioEl.currentTime).toBe(25);
});


test("headphone pause publishes the real speaker position with an ownership guard", async () => {
  const c = controller();
  await c.apply(state(7));
  c.advanceAudio(42.5);
  c.audioEl.pause();
  c.mediaPause();
  c.mediaPause();
  expect(c.commands).toEqual([{kind:"pause",target_device_id:"web",expectedRevision:7,position_seconds:42.5}]);
  expect(c.displayed().isPlaying).toBe(false);
  await Promise.resolve();
  expect(c.state().state).toBe("paused");
});

test("external resume publishes play once without replacing the queue", async () => {
  const c = controller();
  await c.apply(state(7,"paused"));
  c.advanceAudio(23);
  await c.audioEl.play();
  c.mediaPlay();
  c.mediaPlay();
  expect(c.commands).toEqual([{kind:"play",target_device_id:"web",expectedRevision:7,position_seconds:23}]);
  expect(c.displayed().isPlaying).toBe(true);
});

test("system pause/play is explicit and repeated actions are idempotent", async () => {
  const c = controller();
  await c.apply(state(7));
  c.systemPlayback(false);
  c.systemPlayback(false);
  c.mediaPause();
  await Promise.resolve();
  expect(c.commands.map((command: {kind:string}) => command.kind)).toEqual(["pause"]);
  c.systemPlayback(true);
  c.systemPlayback(true);
  c.mediaPlay();
  await Promise.resolve();
  expect(c.commands.map((command: {kind:string}) => command.kind)).toEqual(["pause","play"]);
});

test("queued app pause/play events cannot echo after the remote guard clears", async () => {
  const c = controller();
  await c.apply(state(1));
  c.appPause();
  await c.appPlay();
  c.mediaPause();
  c.mediaPlay();
  expect(c.displayed().isPlaying).toBe(true);
  expect(c.commands).toEqual([]);
  await c.apply(state(2,"paused"));
  await c.apply(state(3));
  expect(c.commands).toEqual([]);
});

test("end of track and failed or empty media never publish a system pause", async () => {
  for (const property of [{ended:true},{error:{code:2}},{readyState:0}]) {
    const c = controller();
    await c.apply(state(1));
    c.audioEl.pause();
    Object.assign(c.audioEl,property);
    c.mediaPause();
    expect(c.commands).toEqual([]);
  }
});

test("stale system handlers cannot pause or claim playback from the phone", async () => {
  const c = controller();
  await c.apply(state(1));
  await c.apply(state(2,"playing","phone"));
  c.systemPlayback(false);
  c.systemPlayback(true);
  expect(c.commands).toEqual([]);
  expect(c.state().active_device_id).toBe("phone");
  expect(c.displayed().isPlaying).toBe(true);
  expect(c.audioEl.paused).toBe(true);
});


test("headphone pause during a buffering play promise is not swallowed by remote reconciliation", async () => {
  const c = controller();
  const release = c.delayPlay();
  const loading = c.apply(state(7));
  for (let i=0; i<5; i++) await Promise.resolve();
  expect(c.counts.plays).toBe(1);
  c.mediaPlay(); // Consume the queued event from the app's still-pending play().
  c.advanceAudio(8);
  c.audioEl.pause();
  c.mediaPause();
  expect(c.commands).toEqual([{kind:"pause",target_device_id:"web",expectedRevision:7,position_seconds:8}]);
  release();
  await loading;
  expect(c.displayed().isPlaying).toBe(false);
  expect(c.state().state).toBe("paused");
});


test("hardware controls cannot undo an outgoing transfer before its acknowledgement", async () => {
  const c = controller();
  await c.apply(state(7));
  c.pendingTarget("phone"); // transferPlaybackToDevice sets this before awaiting the server.
  c.audioEl.pause();
  c.mediaPause();
  c.systemPlayback(false);
  c.systemPlayback(true);
  c.audioEl.paused = false;
  c.mediaPlay();
  expect(c.commands).toEqual([]);
  expect(c.audioEl.paused).toBe(true);
  expect(c.displayed().selectedPlaybackDeviceId).toBe("phone");
  await c.apply(state(8,"playing","phone"));
  expect(c.displayed().isPlaying).toBe(true);
  expect(c.commands).toEqual([]);
});

function endedController(synced = true, repeat = "one") {
  const functions = ["handleEnded", "startPlayback", "audioSourceIdentity", "playLocalAudio", "attachAux"]
    .map(controllerFunction).join("\n");
  const source = `
    let auxConnection = null, auxBridge = null;
    async function refreshAuxState() {}
    let auxInheritedFingerprint='',auxState=null,auxInviteSecret='',auxCode='',guestMode=false,auxInvitation=null,auxCreateOpen=false,settingsModalOpen=false;
    let playbackConnectionGeneration=0,playbackApplyGeneration=0,pendingPlaybackCommands=0,deferredPlaybackState=null;
    const visualizerSampler=null;
    const savePlaybackSessionNow=()=>{},resetPlaybackCommandQueue=()=>{},saveAuxConnection=()=>{},stopPlaybackClock=()=>{};
    let currentTime = 300, currentTrack = {id:"song",fingerprint:"song",duration_seconds:300};
    let repeatMode = repeat, localPlaybackGeneration = 0, syncReadGeneration = 1;
    let playbackClockSuppressUntil = 0, isPlaying = false, errorMessage = "";
    const deviceId = "web", rootPath = "loud://sync-server";
    const playbackStateV2 = {active_device_id:deviceId};
    const usePlaybackSync = () => synced;
    const playbackAudioSession = {begin(){}};
    let audioGraphContext = null, expectedAudioPlayEvents = 0;
    const loadedSource = "https://codec.test/song.mp3";
    let nextCompletion = Promise.resolve();
    const playPositions = [], commands = [], notifications = [];
    // Deliberately do not dispatch timeupdate when the element is reset:
    // browser events may arrive after the repeat-one restart is underway.
    const audioEl = {currentTime:300,paused:true,error:null,
      async play(){playPositions.push(this.currentTime);this.paused=false}};
    const tick = () => Promise.resolve();
    const playbackUrlForTrack = async () => loadedSource;
    const waitForAudioMetadata = async () => {};
    const applyPendingSeek = () => {};
    const mediaErrorMessage = error => String(error);
    function loadAudioSource(){throw new Error("Repeat must retain its loaded source")}
    async function localNextTrack(){currentTrack={...currentTrack,id:"next"};await nextCompletion}
    async function nextTrack(){throw new Error("Unexpected unsynchronized next")}
    function notifyServerAfterLocalChange(before,kind){notifications.push({before,kind})}
    async function sendPlaybackCommand(kind,options){commands.push({kind,...options});return {}}
    async function applyPlaybackStateV2(){}
    ${functions}
    return {
      end:handleEnded, playPositions, commands, notifications,
      position:()=>({page:currentTime,audio:audioEl.currentTime}),
      transfer:()=>{playbackStateV2.active_device_id="phone"},
      switchConnection:()=>{syncReadGeneration++},
      attachAux:()=>attachAux({role:"host",session_id:"aux-session"},null),
      holdNext:()=>{let release;nextCompletion=new Promise(resolve=>{release=resolve});return release}
    };
  `;
  return new Function("synced", "repeat", new Bun.Transpiler({loader:"ts"}).transformSync(source))(synced, repeat);
}

for (const synced of [false, true]) {
  test(`repeat-one restarts at zero before a delayed timeupdate (${synced ? "synced" : "local"})`, async () => {
    const c = endedController(synced);
    await c.end();
    expect(c.playPositions).toEqual([0]);
    expect(c.position()).toEqual({page:0,audio:0});
    expect(c.commands).toEqual(synced ? [{kind:"seek",target_device_id:"web",position_seconds:0}] : []);
  });
}

for (const change of ["transfer", "switchConnection", "attachAux"] as const) {
  test(`a delayed ended transition cannot publish after ${change}`, async () => {
    const c = endedController(true, "off");
    const release = c.holdNext();
    const ending = c.end();
    c[change]();
    release();
    await ending;
    expect(c.notifications).toEqual([]);
    expect(c.commands).toEqual([]);
  });
}

test("a delayed ended transition still publishes while connection and owner stay current", async () => {
  const c = endedController(true, "off");
  const release = c.holdNext();
  const ending = c.end();
  release();
  await ending;
  expect(c.notifications).toEqual([{before:"song",kind:"next"}]);
});


test("Aux handoff invalidates an owner metadata read without stopping the inherited element", async () => {
  const c = controller();
  const release = c.delayMetadata();
  const loading = c.apply(state(1));
  await Promise.resolve();
  c.attachAux();
  c.audioEl.paused = false; // The Aux listener inherited this selected host element.
  const pauses = c.counts.pauses;
  release();
  await loading;
  expect(c.counts.plays).toBe(0);
  expect(c.counts.pauses).toBe(pauses);
  expect(c.audioEl.paused).toBe(false);
});

test("a pending owner graph suspension cannot release the new Aux listener", async () => {
  const c = controller();
  const release = c.delayedGraph();
  await c.apply(state(1, "playing", "phone"));
  c.attachAux();
  c.audioEl.paused = false;
  const releases = c.counts.graphReleases;
  release();
  await Promise.resolve();
  await Promise.resolve();
  expect(c.counts.graphResumes).toBe(1);
  expect(c.counts.graphReleases).toBe(releases);
  expect(c.audioEl.paused).toBe(false);
});

test("Aux local pause/play/error events never send personal playback commands", async () => {
  const c = controller();
  await c.apply(state(1));
  c.attachAux();
  c.audioEl.paused = true;
  c.mediaPause();
  c.audioEl.paused = false;
  c.mediaPlay();
  c.mediaError();
  await Promise.resolve();
  expect(c.commands).toEqual([]);
  expect(c.audioEl.paused).toBe(false);
});

test("the personal command entrypoint rejects late commands after Aux attaches", async () => {
  let sent = 0;
  const source = `let auxConnection={session_id:"aux"},auxBridge=null;${controllerFunction("sendPlaybackCommand")}return sendPlaybackCommand;`;
  const send = new Function("sendPlaybackCommandV2", new Bun.Transpiler({loader:"ts"}).transformSync(source))(() => { sent++; });
  await expect(send("pause")).rejects.toThrow();
  expect(sent).toBe(0);
});
