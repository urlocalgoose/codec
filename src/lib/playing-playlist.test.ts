import { expect, test } from "bun:test";
import { createQueue, shuffleTracks, sortTracks } from "./library";
import { normalizePlaybackContextV2 } from "./sync";
import { parsePlaybackSession } from "./playback-session";

const page = await Bun.file(new URL("../routes/+page.svelte", import.meta.url)).text();
function controllerFunction(name: string) {
  const start = page.search(new RegExp(`  (?:async )?function ${name}\\(`));
  if (start < 0) throw new Error(`Missing controller function ${name}`);
  return page.slice(start, page.indexOf("\n  }", start) + 4);
}
const song = (id: string) => ({ id, path: id, fingerprint: id, added_at: 1 });
const a = song("shared"), b = song("second"), other = song("unrelated");

// Exercise the page's actual start/context/shuffle code with audio and transport
// as boundaries; matching track membership deliberately cannot identify origin.
function controller(sync = false, local = true) {
  const functions = ["playTrack", "playTrackSet", "playTrackRow", "selectedSourcePlaylistID", "playbackContextSnapshot", "applyPlaybackContextV2", "toggleShuffle"].map(controllerFunction).join("\n");
  const source = `
    let playbackSource=[],sourcePlaylistID=null,playbackIndex=0,queuedTracks=[],playHistory=[];
    let currentTrack=null,currentTime=0,isPlaying=false,shuffle=false,repeatMode='off',errorMessage='';
    let library={tracks:[],playlists:[{id:'liked-id',is_liked:true}]};
    let selectedView='home',selectedPlaylist=null,globalSearch=false,mobileCollection=null,visibleTracks=[];
    const SHUFFLE_STORAGE_KEY='',REPEAT_STORAGE_KEY='',deviceId='web';
    let loads=0,toggles=0;const sent=[];
    const trackReference=track=>track;
    const tracksFromReferences=(_library,refs)=>refs;
    const usePlaybackSync=()=>sync;
    const selectedPlaybackTargetDeviceId=()=>local?'web':'phone';
    const recordPlaylistPlay=()=>{};const writeStoredValue=()=>{};
    async function startPlayback(){loads++;isPlaying=true}
    async function togglePlayback(){toggles++;isPlaying=!isPlaying}
    async function playQueueTrack(){throw new Error('Not part of fixture')}
    async function sendPlaybackCommand(kind,body){sent.push({kind,...body});if(body.context)applyPlaybackContextV2({context:body.context});return {context:body.context}}
    async function applyPlaybackStateV2(state){if(state.context)applyPlaybackContextV2(state)}
    function currentPlaybackTimeForSave(){return currentTime}
    ${functions}
    return {play:playTrack,all:playTrackSet,row:playTrackRow,flipShuffle:toggleShuffle,snapshot:playbackContextSnapshot,apply:applyPlaybackContextV2,
      screen(id,tracks,search=false){selectedView=id??'home';selectedPlaylist=id&&id!=='liked'?{id}:null;visibleTracks=tracks;globalSearch=search},
      queued(track){queuedTracks.push(track)},setLibrary(value){library=value},
      state:()=>({sourcePlaylistID,playbackSource,currentTrack,loads,toggles,sent,shuffle,errorMessage})};
  `;
  return new Function("sync", "local", "createQueue", "shuffleTracks", "sortTracks", new Bun.Transpiler({ loader: "ts" }).transformSync(source))(sync, local, createQueue, shuffleTracks, sortTracks);
}

test("explicit playlist starts identify the source even when playlists share the same songs", async () => {
  for (const [sync, local] of [[false,true],[true,true],[true,false]]) {
    const c = controller(sync,local);
    c.screen("one",[a,b]); await c.all([a,b]);
    expect(c.snapshot().playlist_id).toBe("one");
    c.screen("two",[a,b]); await c.all([a,b]);
    expect(c.snapshot().playlist_id).toBe("two");
    if(sync) expect(c.state().sent.at(-1).context.playlist_id).toBe("two");
    expect(c.state().loads).toBe(!sync || local ? 2 : 0);
  }
});

test("same-song pause/resume from another screen preserves the actual queue's origin", async () => {
  const c = controller(); c.screen("one",[a,b]); await c.all([a,b]);
  c.screen("two",[a,b]); await c.row(a,0);
  expect(c.snapshot().playlist_id).toBe("one");
  expect(c.state().toggles).toBe(1);
  expect(c.state().loads).toBe(1);
});

test("new generic/search collection clears provenance and Liked Songs uses its real ID", async () => {
  const c = controller(true); c.screen("one",[a,b]); await c.all([a,b]);
  await c.play(other,[other]); expect(c.snapshot().playlist_id).toBeNull();
  c.screen("one",[a,b],true); await c.all([a,b]); expect(c.snapshot().playlist_id).toBeNull();
  c.screen("liked",[a,b]); await c.all([a,b]); expect(c.snapshot().playlist_id).toBe("liked-id");
});

test("manual queue edits and shuffle after navigating Home retain source membership and identity", async () => {
  for(const sync of [false,true]) {
    const c=controller(sync);c.screen("one",[a,b]);await c.all([a,b]);
    c.queued(other); c.screen(null,[other]); await c.flipShuffle(); await c.flipShuffle();
    const context=c.snapshot();
    expect(context.playlist_id).toBe("one");
    expect(context.playback_source.map((t: {id:string})=>t.id).sort()).toEqual([a.id,b.id].sort());
    expect(context.queued_tracks).toEqual([other]);
  }
});

test("receiving a new origin updates it without audio work; old clients clear stale identity", async () => {
  const c=controller();c.screen("one",[a,b]);await c.all([a,b]);
  c.apply({context:{...c.snapshot(),playlist_id:"two"}});
  expect(c.snapshot().playlist_id).toBe("two");expect(c.state().loads).toBe(1);
  const old=c.snapshot();delete old.playlist_id;c.apply({context:old});
  expect(c.snapshot().playlist_id).toBeNull();expect(c.state().loads).toBe(1);
});

test("wire context normalizes explicit IDs and never guesses an absent origin", () => {
  expect(normalizePlaybackContextV2({playlist_id:"  mix  "}).playlist_id).toBe("mix");
  for(const value of [null,undefined,"", "  ",42,{}]) {
    const context=normalizePlaybackContextV2({playlist_id:value as string,playback_source:[a,b]});
    expect(context.playlist_id).toBeNull();
  }
});

test("local session restore keeps explicit source, tolerates legacy saves, and rejects a different root", () => {
  const session={schema:"loud.playback.v1",root_path:"fixture",saved_at:1,playlist_id:"one",playback_source:[a,b],current_track:a};
  expect(parsePlaybackSession(JSON.stringify(session),"fixture")?.playlist_id).toBe("one");
  expect(parsePlaybackSession(JSON.stringify({...session,playlist_id:undefined}),"fixture")?.playlist_id).toBeNull();
  expect(parsePlaybackSession(JSON.stringify(session),"another-server")).toBeNull();
});
