import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Native playback is represented by an isolated server fixture. This exercises
// actual mobile WebKit UI, SSE, foreground recovery and command targeting.
const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const moduleURL = moduleName.startsWith('/') || moduleName.startsWith('.') ? pathToFileURL(path.resolve(moduleName)).href : moduleName;
const { webkit } = await import(moduleURL);
const build = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '../build'));
const output = process.argv[3] ?? '/tmp/codec-mobile-handoff-regression.json';
const tracks = ['Native now playing', 'Next from iPhone', 'New remote song'].map((title, index) => ({
  id: `song-${index}`, path: `loud://track/song-${index}`, file_name: `song-${index}.mp3`, title,
  artist: 'Handoff fixture', album: 'Remote session', duration_seconds: 300, artwork_url: null,
  playlist_ids: [], is_liked: false, fingerprint: `song-${index}`, added_at: 1700000000, size_bytes: 1000
}));
const ref = track => ({ id: track.id, path: track.path, fingerprint: track.fingerprint });
const library = { root_path: 'loud://fixture', scanned_at: 1700000000, tracks, playlists: [], artists: [], albums: [],
  stats: { trackCount: tracks.length, playlistCount: 0, likedCount: 0, artistCount: 1, albumCount: 1, durationSeconds: 900 } };
let state = { schema: 'loud.playback.v2', revision: 10, active_device_id: 'native-iphone', state: 'playing', track: ref(tracks[0]),
  context: { playback_source: tracks.map(ref), playback_index: 0, queued_tracks: [ref(tracks[1])], play_history: [], shuffle: false, repeat: 'off' },
  clock: { position_seconds: 42, started_at_ms: Date.now(), updated_at_ms: Date.now() }, volume: 1, server_time_ms: Date.now() };
const snapshot = () => ({ ...state, server_time_ms: Date.now() });
const legacy = { session: { schema: 'loud.playback.v1', root_path: library.root_path, saved_at: Date.now() + 60000,
  selected_view: 'home', current_track: ref(tracks[2]), current_time: 0, audio_duration: 300,
  playback_source: [], playback_index: 0, queued_tracks: [], play_history: [] } };
const subscribers = new Set(), legacyResponses = new Set(), commands = [], errors = [];
let origin, eventConnections = 0, audioRequests = 0, healthAvailable = true, holdDiscovery = false, streamSnapshots = true;
const discoveryResponses = new Set(), heldSnapshots = new Set();
let holdPlaybackReads = false, onHeldPlayback = () => {}, abortedSnapshots = 0;
const publish = (serverTime = Date.now()) => { for (const response of subscribers) response.write(`event: playback_state\ndata: ${JSON.stringify({type:'playback_state', playback_state:{...snapshot(),server_time_ms:serverTime}})}\n\n`); };
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, origin ?? 'http://127.0.0.1');
    const json = (value, status=200) => { res.writeHead(status, {'Content-Type':'application/json','Cache-Control':'no-store'}); res.end(JSON.stringify(value)); };
    if (url.pathname === '/health') return json({ok:healthAvailable,schema:'loud.sync.v1',playback_schema:'loud.playback.v2',server_id:'isolated-handoff'},healthAvailable ? 200 : 503);
    if (url.pathname === '/api/v1/library') return json(library);
    if (url.pathname === '/api/v1/auth/stream-token') return json({token:'fixture-only-token',expires_at:Math.floor(Date.now()/1000)+900},201);
    if (url.pathname === '/api/v2/playback') {
      if (holdPlaybackReads) {
        heldSnapshots.add(res); onHeldPlayback();
        res.on('close',()=>{if(!res.writableEnded)abortedSnapshots++;});
        return;
      }
      return json(snapshot());
    }
    if (url.pathname === '/api/v2/playback/events') {
      eventConnections++;
      res.writeHead(200, {'Content-Type':'text/event-stream','Cache-Control':'no-cache','Connection':'keep-alive'});
      subscribers.add(res); req.on('close', () => subscribers.delete(res));
      if (streamSnapshots) res.write(`event: playback_state\ndata: ${JSON.stringify({type:'playback_state',playback_state:snapshot()})}\n\n`);
      else res.write(': suspended fixture\n\n');
      return;
    }
    // Discovery deliberately lacks the still-playing background native device.
    if (url.pathname === '/api/v1/playback/devices' && req.method === 'GET' && holdDiscovery) { discoveryResponses.add(res); return; }
    if (url.pathname.includes('/playback/devices')) return json(req.method === 'GET' ? [{device_id:'web-iphone',name:'iPhone Web',updated_at:Date.now()}] : {});
    if (url.pathname === '/api/v1/playback-session/latest') { legacyResponses.add(res); return; }
    if (url.pathname === '/api/v2/playback/commands') {
      let body=''; for await (const chunk of req) body += chunk;
      const command=JSON.parse(body); commands.push(command);
      if (command.kind === 'pause') state={...state,revision:state.revision+1,state:'paused',clock:{...state.clock,started_at_ms:null,position_seconds:command.position_seconds ?? 42,updated_at_ms:Date.now()}};
      json(snapshot()); publish(); return;
    }
    if (url.pathname.includes('/audio')) { audioRequests++; return json({error:'Remote control must not stream music'},500); }
    if (url.pathname.startsWith('/api/')) return json([]);
    const file = path.resolve(build, '.' + (url.pathname === '/' ? '/index.html' : decodeURIComponent(url.pathname)));
    if (!file.startsWith(build + path.sep)) { res.writeHead(403).end(); return; }
    const bytes = await fs.readFile(file);
    res.writeHead(200, {'Content-Type':({'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.woff2':'font/woff2'})[path.extname(file)] ?? 'application/octet-stream'}); res.end(bytes);
  } catch { if (!res.headersSent) res.writeHead(404); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
const browser = await webkit.launch({headless:true});
const context = await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true,serviceWorkers:'block'});
await context.addInitScript(() => {
  localStorage.setItem('codec.syncServer',location.origin);
  localStorage.setItem('codec.syncToken','fixture-only-token');
  localStorage.setItem('codec.deviceId','web-iphone');
  localStorage.setItem('codec.musicRoot','loud://sync-server');
  localStorage.setItem('codec.deviceName','iPhone Web');
  window.__plays=0; window.__audioContexts=0;
  if (window.AudioContext) {
    window.AudioContext=new Proxy(window.AudioContext,{construct(target,args){window.__audioContexts++;return Reflect.construct(target,args);}});
  }
  const original=HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play=function(...args){window.__plays++;return original.apply(this,args);};
});
const page=await context.newPage(); page.on('pageerror',error=>errors.push(error.message));
await page.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
const report={build,browser:'WebKit',checks:[],errors};
try {
  const started=Date.now(); await page.goto(origin);
  const mini=page.locator('.mobile-mini-player');
  await mini.getByRole('button',{name:'Pause',exact:true}).waitFor({timeout:10000});
  assert.match(await mini.textContent(),/Native now playing/);
  report.checks.push({name:'Cold open reflects native playback before legacy session completes',elapsedMs:Date.now()-started});
  assert(legacyResponses.size>0,'Fixture must hold a legacy response while live playback is visible');
  for (const response of legacyResponses) { response.writeHead(200,{'Content-Type':'application/json'}); response.end(JSON.stringify(legacy)); }
  legacyResponses.clear(); await page.waitForTimeout(150);
  assert.match(await mini.textContent(),/Native now playing/);
  report.checks.push({name:'Late legacy restore does not overwrite native track'});
  await mini.getByRole('button',{name:/Open Now Playing/}).click();
  const seek=page.getByRole('slider',{name:'Seek',exact:true}); await seek.waitFor();
  assert(Number(await seek.inputValue())>=42);
  await page.getByRole('button',{name:'Queue',exact:true}).click();
  await page.getByRole('button',{name:'Play Next from iPhone',exact:true}).first().waitFor();
  report.checks.push({name:'Native position and queue are displayed'});
  // Keep the screen open and deliver an actual named SSE event.
  state={...state,revision:11,track:ref(tracks[2]),context:{...state.context,playback_index:2,queued_tracks:[]},clock:{...state.clock,position_seconds:75,started_at_ms:Date.now(),updated_at_ms:Date.now()}};
  const eventAt=Date.now(); publish();
  await page.waitForFunction(()=>document.querySelector('.mobile-mini-summary')?.textContent?.includes('New remote song'));
  report.checks.push({name:'Live native track update over SSE',elapsedMs:Date.now()-eventAt});
  // No SSE broadcast: returning to the browser must repair a missed update.
  state={...state,revision:12,track:ref(tracks[0]),context:{...state.context,playback_index:0},clock:{...state.clock,position_seconds:80,started_at_ms:Date.now()-20_000,updated_at_ms:Date.now()-20_000}};
  const connectionCount=eventConnections, resumeAt=Date.now();
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
  await page.waitForFunction(()=>document.querySelector('.mobile-mini-summary')?.textContent?.includes('Native now playing'));
  await page.waitForTimeout(100); assert(eventConnections>connectionCount);
  report.checks.push({name:'Returning to web repairs missed state and replaces suspended SSE',elapsedMs:Date.now()-resumeAt});
  // A late event must not reinterpret five seconds of socket delay as a
  // change to the server's clock.
  await page.keyboard.press('Escape');
  await page.getByRole('dialog',{name:'Queue',exact:true}).waitFor({state:'hidden'});
  const beforeDelayed=Number(await seek.inputValue());
  state={...state,revision:state.revision+1}; publish(Date.now()-5000);
  await page.waitForTimeout(200);
  assert(Number(await seek.inputValue())>=beforeDelayed-.2,'Delayed SSE must not rewind remote progress');
  report.checks.push({name:'Delayed SSE keeps the native timeline continuous'});
  // No initial SSE state and a hanging discovery endpoint: the independent
  // playback read must still update the current song on foreground.
  holdDiscovery=true; streamSnapshots=false;
  state={...state,revision:state.revision+1,track:ref(tracks[2]),clock:{...state.clock,position_seconds:125,started_at_ms:Date.now(),updated_at_ms:Date.now()}};
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
  await page.waitForFunction(()=>document.querySelector('.mobile-mini-summary')?.textContent?.includes('New remote song'));
  assert(discoveryResponses.size>0,'Fixture must hold device discovery while playback updates');
  report.checks.push({name:'Stalled discovery cannot block live playback refresh'});
  for (const response of discoveryResponses) { response.writeHead(200,{'Content-Type':'application/json'}); response.end('[]'); }
  discoveryResponses.clear(); holdDiscovery=false; streamSnapshots=true;
  // Replace a request started before suspension rather than waiting for
  // the old connection or its timeout to complete.
  streamSnapshots=false; holdPlaybackReads=true;
  const heldReadStarted=new Promise(resolve=>{onHeldPlayback=resolve;});
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
  await heldReadStarted;
  const stale=snapshot(); holdPlaybackReads=false;
  state={...state,revision:state.revision+1,track:ref(tracks[1]),clock:{...state.clock,position_seconds:130,started_at_ms:Date.now(),updated_at_ms:Date.now()}};
  const recoveryAt=Date.now();
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
  await page.waitForFunction(()=>document.querySelector('.mobile-mini-summary')?.textContent?.includes('Next from iPhone'));
  await page.waitForTimeout(50);
  assert(abortedSnapshots>0,'Foreground must abort the old snapshot connection');
  for(const response of heldSnapshots){if(!response.destroyed){response.writeHead(200,{'Content-Type':'application/json'});response.end(JSON.stringify(stale));}}
  heldSnapshots.clear(); streamSnapshots=true;
  assert.match(await mini.textContent(),/Next from iPhone/);
  report.checks.push({name:'Foreground supersedes suspended playback GET without waiting for its timeout',elapsedMs:Date.now()-recoveryAt});
  assert.equal(commands.length,0,'Opening and observing web must send no playback command');
  assert.equal(audioRequests,0,'Remote control must not duplicate the native audio stream');
  assert.equal(await page.evaluate(()=>window.__plays),0,'Web must not attempt local playback');
  // Close Now Playing before testing the mini player's explicit transport.
  await page.keyboard.press('Escape');
  await page.getByRole('dialog',{name:'Now Playing',exact:true}).waitFor({state:'hidden'});
  await mini.getByRole('button',{name:'Pause',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.mobile-mini-player button[aria-label="Play"]'));
  assert.equal(commands.at(-1).kind,'pause'); assert.equal(commands.at(-1).target_device_id,'native-iphone');
  report.checks.push({name:'Explicit web pause still targets the native owner without its heartbeat'});
  // A saved tab opened while the server is unavailable must recover when
  // connectivity returns, without making the user reconnect manually.
  healthAvailable=false;
  const offlinePage=await context.newPage(); offlinePage.on('pageerror',error=>errors.push(error.message));
  await offlinePage.goto(origin);
  await offlinePage.getByText('Could not reach Codec sync server (503).',{exact:false}).first().waitFor();
  healthAvailable=true;
  state={...state,revision:state.revision+1,state:'playing',track:ref(tracks[2]),clock:{...state.clock,position_seconds:150,started_at_ms:Date.now(),updated_at_ms:Date.now()}};
  await offlinePage.evaluate(()=>window.dispatchEvent(new Event('online')));
  await offlinePage.locator('.mobile-mini-player').getByRole('button',{name:'Pause',exact:true}).waitFor();
  assert.match(await offlinePage.locator('.mobile-mini-summary').textContent(),/New remote song/);
  assert.equal(commands.length,1,'Offline recovery must not claim or pause native playback');
  assert.equal(audioRequests,0);
  report.checks.push({name:'Offline startup reconnects and follows native when service returns'});
  await offlinePage.close();
  await page.getByRole('button',{name:'Visualizer',exact:true}).click();
  await page.locator('.visualizer-view').waitFor();
  assert.equal(await page.evaluate(()=>window.__audioContexts),0,'Remote visualizer must not activate a competing Web Audio session');
  report.checks.push({name:'Remote visualizer creates no local audio session'});
  assert.equal(errors.length,0);
} finally {
  report.commands=commands.map(({kind,target_device_id})=>({kind,target_device_id})); report.audioRequests=audioRequests; report.eventConnections=eventConnections;
  await fs.writeFile(output,JSON.stringify(report,null,2)); console.log(JSON.stringify(report,null,2));
  await browser.close(); for (const response of subscribers) response.end(); for (const response of legacyResponses) response.end(); for (const response of discoveryResponses) response.end(); for (const response of heldSnapshots) response.end();
  server.closeAllConnections(); await new Promise(resolve=>server.close(resolve));
}
