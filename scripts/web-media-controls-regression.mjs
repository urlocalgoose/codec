import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';

// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/web-media-controls-regression.mjs [build-dir] [report.json]
// Optional: PLAYWRIGHT_BROWSER=webkit, PLAYWRIGHT_BROWSER_PATH=/path/to/chromium.
// Uses generated audio, local fixtures and two isolated browser contexts only.
// MediaSession callbacks are captured at registration; actual audio methods and
// native media events remain intact. This does not emulate a Bluetooth device.
const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const moduleURL = /^[./]/.test(moduleName) ? pathToFileURL(path.resolve(moduleName)).href : moduleName;
const engines = await import(moduleURL);
const engineName = process.env.PLAYWRIGHT_BROWSER ?? 'chromium';
assert(['chromium', 'webkit'].includes(engineName), 'Use Chromium or WebKit');
const build = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '../build'));
const output = path.resolve(process.argv[3] ?? '/tmp/codec-web-media-controls-regression.json');
await fs.access(path.join(build, 'index.html'));

const seconds = 90, sampleRate = 22050;
const wave = Buffer.alloc(44 + sampleRate * seconds * 2);
wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8);
wave.writeUInt32LE(16, 16); wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22);
wave.writeUInt32LE(sampleRate, 24); wave.writeUInt32LE(sampleRate * 2, 28);
wave.writeUInt16LE(2, 32); wave.writeUInt16LE(16, 34); wave.write('data', 36);
wave.writeUInt32LE(wave.length - 44, 40);
for (let i = 0; i < sampleRate * seconds; i++) wave.writeInt16LE(Math.round(Math.sin(i * 2 * Math.PI * 220 / sampleRate) * 500), 44 + i * 2);

const speakerID = 'media-speaker', observerID = 'media-observer';
const tracks = ['first', 'second'].map((name, index) => ({
  id: `fixture-${name}`, path: `loud://track/fixture-${name}`, fingerprint: `fixture-${name}`,
  file_name: `${name}.wav`, title: `Generated tone ${index + 1}`, artist: 'Isolated audio fixture',
  album: 'Media control test', duration_seconds: seconds, artwork_url: null, playlist_ids: [],
  is_liked: false, added_at: 1700000000 + index, size_bytes: wave.length,
}));
const reference = track => ({ id: track.id, path: track.path, fingerprint: track.fingerprint });
const refs = tracks.map(reference);
const library = { root_path: 'loud://media-fixture', scanned_at: 1700000000, tracks, playlists: [], artists: [], albums: [],
  stats: { trackCount: 2, playlistCount: 0, likedCount: 0, artistCount: 1, albumCount: 1, durationSeconds: seconds * 2 } };
let state = { schema: 'loud.playback.v2', revision: 1, active_device_id: speakerID, state: 'playing', track: refs[0],
  context: { playback_source: refs, playback_index: 0, queued_tracks: [], play_history: [], shuffle: false, repeat: 'off' },
  clock: { position_seconds: 10, started_at_ms: Date.now(), stopped_at_ms: null, updated_at_ms: Date.now() },
  volume: 0, server_time_ms: Date.now() };
let origin, audioRequests = 0, tokenCount = 0, holdNextTransportReply = false;
const heldReplies = [];
const subscribers = new Set(), sockets = new Set(), commands = [], errors = [], fixtureErrors = [];
const report = { passed: false, build, browser: engineName, synthetic: true, checks: [], errors, fixtureErrors };
const snapshot = () => ({ ...state, server_time_ms: Date.now() });
const position = () => state.clock.position_seconds + (state.state === 'playing' && state.clock.started_at_ms ? (Date.now() - state.clock.started_at_ms) / 1000 : 0);
function clock(at, playing) { const now = Date.now(); return { position_seconds: at, started_at_ms: playing ? now : null, stopped_at_ms: playing ? null : now, updated_at_ms: now }; }
function broadcast() { for (const response of subscribers) response.write(`event: playback_state\ndata: ${JSON.stringify({ type: 'playback_state', playback_state: snapshot() })}\n\n`); }
function remote(patch) {
  const nextStatus = patch.state ?? state.state;
  state = { ...state, ...patch, revision: state.revision + 1, clock: patch.clock ?? clock(position(), nextStatus === 'playing') };
  broadcast();
}
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, origin ?? 'http://127.0.0.1');
    const json = (value, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/health') return json({ ok: true, schema: 'loud.sync.v1', playback_schema: 'loud.playback.v2', server_id: 'isolated-media-controls' });
    if (url.pathname === '/api/v1/library') return json(library);
    if (url.pathname === '/api/v1/auth/stream-token') return json({ token: `stream_fixture_${++tokenCount}`, expires_at: Math.floor(Date.now() / 1000) + 900 }, 201);
    if (url.pathname === '/api/v2/playback/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
      res.write(': fixture\n\n'); subscribers.add(res); req.on('close', () => subscribers.delete(res)); return;
    }
    if (url.pathname === '/api/v2/playback') return json(snapshot());
    if (url.pathname.includes('/playback/devices')) return json(req.method === 'GET' ? [speakerID, observerID, 'native-fixture'].map(id => ({ device_id: id, name: id, updated_at: Date.now() })) : {});
    if (url.pathname === '/api/v2/playback/commands') {
      let body = ''; for await (const chunk of req) body += chunk;
      const command = JSON.parse(body);
      const expected = req.headers['if-match'];
      commands.push({ ...command, expected_revision: expected ?? null });
      if (expected && Number(String(expected).replaceAll('"', '')) !== state.revision) return json({ error: 'Fixture revision conflict' }, 409);
      const at = command.position_seconds ?? position();
      const target = command.target_device_id ?? command.device_id;
      if (command.context) state.context = command.context;
      if (command.track) state.track = command.track;
      switch (command.kind) {
        case 'pause': state.state = 'paused'; state.active_device_id = target; break;
        case 'play': state.state = 'playing'; state.active_device_id = target; break;
        case 'seek': state.active_device_id = target; break;
        case 'transfer': state.active_device_id = target; break;
        case 'next': {
          const index = refs.findIndex(ref => ref.id === state.track?.id);
          if (index + 1 < refs.length) { state.track = refs[index + 1]; state.context = { ...state.context, playback_index: index + 1 }; }
          else state.state = 'paused';
          state.active_device_id = target; break;
        }
        case 'set_queue': case 'set_shuffle': case 'set_repeat': case 'volume': break;
        default: throw new Error(`Unexpected fixture command ${command.kind}`);
      }
      state = { ...state, revision: state.revision + 1, clock: clock(command.kind === 'next' ? 0 : at, state.state === 'playing') };
      const reply = () => { json(snapshot()); broadcast(); };
      if (holdNextTransportReply && ['play', 'pause', 'transfer'].includes(command.kind)) {
        holdNextTransportReply = false; heldReplies.push(reply); return;
      }
      reply(); return;
    }
    if (url.pathname.endsWith('/audio')) {
      audioRequests++;
      let start = 0, end = wave.length - 1;
      const range = /bytes=(\d+)-(\d*)/.exec(req.headers.range ?? '');
      if (range) { start = Number(range[1]); if (range[2]) end = Math.min(Number(range[2]), end); }
      if (start > end) { res.writeHead(416, { 'Content-Range': `bytes */${wave.length}` }); res.end(); return; }
      const headers = { 'Content-Type': 'audio/wav', 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store', 'Content-Length': end - start + 1 };
      if (range) headers['Content-Range'] = `bytes ${start}-${end}/${wave.length}`;
      res.writeHead(range ? 206 : 200, headers); res.end(wave.subarray(start, end + 1)); return;
    }
    if (url.pathname.startsWith('/api/')) return json([]);
    const name = path.resolve(build, '.' + (url.pathname === '/' ? '/index.html' : decodeURIComponent(url.pathname)));
    if (!name.startsWith(build + path.sep)) { res.writeHead(403); res.end(); return; }
    const data = await fs.readFile(name);
    res.writeHead(200, { 'Content-Type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.ttf': 'font/ttf', '.woff2': 'font/woff2' })[path.extname(name)] ?? 'application/octet-stream' }); res.end(data);
  } catch (error) { if (req.url.startsWith('/api/')) fixtureErrors.push(error.message); res.writeHead(404); res.end(); }
});
server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
let browser;
const pages = {};
const started = performance.now();
async function waitUntil(condition, message, timeout = 3000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (await condition()) return; await new Promise(resolve => setTimeout(resolve, 25)); }
  assert.fail(message);
}
async function quietCommands(count, message) { await new Promise(resolve => setTimeout(resolve, 180)); assert.equal(commands.length, count, message); }
function passed(name, detail = {}) { report.checks.push({ name, passed: true, ...detail }); }
try {
  browser = await engines[engineName].launch({ headless: true,
    ...(process.env.PLAYWRIGHT_BROWSER_PATH ? { executablePath: process.env.PLAYWRIGHT_BROWSER_PATH } : {}),
    ...(engineName === 'chromium' ? { args: ['--autoplay-policy=no-user-gesture-required'] } : {}) });
  async function client(device) {
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: 'block' });
    await context.addInitScript(({ device }) => {
      localStorage.setItem('codec.syncServer', location.origin); localStorage.setItem('codec.syncToken', 'fixture-token'); localStorage.setItem('codec.deviceId', device);
      window.__mediaControls = { handlers: {}, calls: [], events: [] };
      if ('mediaSession' in navigator) {
        const original = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
        navigator.mediaSession.setActionHandler = (action, callback) => { window.__mediaControls.handlers[action] = callback; return original(action, callback); };
      }
      for (const method of ['play', 'pause', 'load']) {
        const original = HTMLMediaElement.prototype[method];
        HTMLMediaElement.prototype[method] = function (...args) {
          if (method === 'play') this.muted = true;
          window.__mediaControls.calls.push({ method, at: this.currentTime });
          return original.apply(this, args);
        };
      }
      for (const type of ['play', 'pause', 'ended', 'emptied', 'error']) document.addEventListener(type, event => {
        if (event.target instanceof HTMLMediaElement) window.__mediaControls.events.push({ type, at: event.target.currentTime, paused: event.target.paused });
      }, true);
    }, { device });
    const page = await context.newPage(); page.setDefaultTimeout(7000);
    page.on('pageerror', error => errors.push({ device, message: error.message }));
    await page.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
    await page.goto(origin, { waitUntil: 'domcontentloaded' });
    await page.locator('audio').waitFor({ state: 'attached' });
    return page;
  }
  const speaker = pages.speaker = await client(speakerID), observer = pages.observer = await client(observerID);
  const isPaused = (page, paused) => page.waitForFunction(paused => document.querySelector('audio')?.paused === paused, paused);
  const uiPaused = (page, paused) => page.waitForFunction(paused => {
    const button = document.querySelector('.player-bar button.play-button, .player-bar .play-button, .play-button');
    const label = button?.getAttribute('aria-label') ?? button?.getAttribute('title');
    return label === (paused ? 'Play' : 'Pause');
  }, paused);
  await isPaused(speaker, false);
  await waitUntil(() => subscribers.size === 2, 'Both clients must receive real SSE');
  await uiPaused(observer, false);
  assert.equal(commands.length, 0, 'Startup reconciliation must not send transport commands');

  const pausePosition = await speaker.evaluate(() => { const audio = document.querySelector('audio'); audio.pause(); return audio.currentTime; });
  await waitUntil(() => state.state === 'paused', 'External audio.pause() did not publish a shared pause');
  await uiPaused(speaker, true); await uiPaused(observer, true);
  assert.equal(commands.length, 1); assert.equal(commands[0].kind, 'pause');
  assert.equal(commands[0].target_device_id, speakerID);
  assert.notEqual(commands[0].expected_revision, null, 'External media events must not overwrite newer ownership');
  assert(Math.abs(commands[0].position_seconds - pausePosition) < 0.3, 'Use real audio position when externally paused');
  passed('external pause updates speaker, shared position and observer over SSE');

  await speaker.evaluate(() => document.querySelector('audio').pause());
  await quietCommands(1, 'Repeated pause must be idempotent'); passed('repeated pause is idempotent');
  await speaker.evaluate(() => document.querySelector('audio').play());
  await waitUntil(() => state.state === 'playing' && commands.length === 2, 'External play did not publish shared resume');
  await uiPaused(observer, false); await isPaused(speaker, false);
  passed('external play resumes shared session');

  const handlers = await speaker.evaluate(() => Object.keys(window.__mediaControls.handlers).filter(name => typeof window.__mediaControls.handlers[name] === 'function'));
  assert(handlers.includes('pause') && handlers.includes('play'), 'MediaSession must register explicit play and pause handlers');
  await speaker.evaluate(() => window.__mediaControls.handlers.pause({ action: 'pause' }));
  await waitUntil(() => state.state === 'paused' && commands.length === 3, 'MediaSession pause failed');
  await uiPaused(observer, true); await isPaused(speaker, true);
  await speaker.evaluate(() => window.__mediaControls.handlers.pause({ action: 'pause' }));
  await quietCommands(3, 'Repeated MediaSession pause must not toggle or publish twice');
  await speaker.evaluate(() => window.__mediaControls.handlers.play({ action: 'play' }));
  await waitUntil(() => state.state === 'playing' && commands.length === 4, 'MediaSession play failed');
  await uiPaused(observer, false); await isPaused(speaker, false);
  passed('MediaSession play/pause are explicit, synced and idempotent');

  const beforeQuick = commands.length;
  holdNextTransportReply = true;
  await speaker.evaluate(() => document.querySelector('audio').pause());
  await waitUntil(() => heldReplies.length === 1 && commands.length === beforeQuick + 1, 'Rapid pause must reach the server before its acknowledgement');
  await speaker.evaluate(() => document.querySelector('audio').play());
  await speaker.waitForTimeout(80);
  assert.equal(heldReplies.length, 1, 'Play must happen while pause acknowledgement is still withheld');
  heldReplies.shift()();
  await waitUntil(() => state.state === 'playing' && commands.length === beforeQuick + 2, 'Resume before pause acknowledgement was lost');
  await isPaused(speaker, false); await uiPaused(observer, false);
  assert.deepEqual(commands.slice(beforeQuick).map(command => command.kind), ['pause', 'play']);
  await quietCommands(beforeQuick + 2, 'Delayed acknowledgements must not produce feedback commands');
  passed('rapid pause then play before acknowledgement preserves newest intent');

  let beforeRemote = commands.length;
  remote({ state: 'paused' }); await isPaused(speaker, true); await uiPaused(observer, true);
  await quietCommands(beforeRemote, 'Applying a remote pause must not echo a pause command');
  remote({ state: 'playing' }); await isPaused(speaker, false); await uiPaused(observer, false);
  await quietCommands(beforeRemote, 'Applying a remote play must not echo a play command');
  passed('remote pause/play produce no feedback commands');

  remote({ track: refs[1], context: { ...state.context, playback_index: 1 }, clock: clock(5, true) });
  await speaker.waitForFunction(() => document.querySelector('audio')?.currentSrc.includes('fixture-second') && !document.querySelector('audio').paused);
  await quietCommands(beforeRemote, 'Track reload pause/play events must not issue transport commands');
  passed('track source replacement preserves playing state without rogue pause');

  holdNextTransportReply = true;
  await speaker.locator('.device-control select').selectOption('native-fixture');
  await waitUntil(() => heldReplies.length === 1 && commands.length === beforeRemote + 1, 'Transfer acknowledgement must remain pending');
  await speaker.evaluate(() => document.querySelector('audio').pause());
  await speaker.waitForTimeout(80);
  assert.equal(heldReplies.length, 1, 'Headphone pause must occur before transfer acknowledgement');
  heldReplies.shift()();
  await quietCommands(beforeRemote + 1, 'Pause during pending transfer must not queue a command that reclaims playback');
  assert.equal(commands.at(-1).kind, 'transfer');
  assert.equal(state.active_device_id, 'native-fixture'); assert.equal(state.state, 'playing');
  beforeRemote = commands.length;
  passed('hardware pause during pending transfer cannot reclaim remote ownership');
  await isPaused(speaker, true); await uiPaused(observer, false);
  await speaker.evaluate(async () => {
    const audio = document.querySelector('audio');
    await audio.play().catch(() => {});
    audio.dispatchEvent(new Event('pause'));
  });
  await isPaused(speaker, true);
  await quietCommands(beforeRemote, 'Late events from former speaker must never claim remote playback');
  assert.equal(state.active_device_id, 'native-fixture'); await uiPaused(observer, false);
  passed('transfer and stale media events retain remote ownership');

  remote({ active_device_id: speakerID, track: refs[0], context: { ...state.context, playback_index: 0 }, clock: clock(20, true) });
  await speaker.waitForFunction(() => document.querySelector('audio')?.currentSrc.includes('fixture-first') && !document.querySelector('audio').paused);
  await quietCommands(beforeRemote, 'Transfer back should not echo transport commands');
  await speaker.evaluate(() => { const audio = document.querySelector('audio'); audio.currentTime = audio.duration - 0.12; });
  await waitUntil(() => state.track.id === refs[1].id, 'Real ended event did not advance the shared queue');
  await speaker.waitForFunction(() => document.querySelector('audio')?.currentSrc.includes('fixture-second') && !document.querySelector('audio').paused);
  await new Promise(resolve => setTimeout(resolve, 180));
  const endCommands = commands.slice(beforeRemote);
  assert.equal(endCommands.length, 1, 'Natural end must emit one intended queue transition');
  assert.equal(endCommands[0].kind, 'play');
  assert.equal(endCommands[0].track?.id, refs[1].id);
  assert.equal(state.state, 'playing');
  const endedEvents = await speaker.evaluate(() => window.__mediaControls.events.filter(event => event.type === 'ended').length);
  assert(endedEvents > 0, 'Must exercise a real ended event');
  passed('real track end advances once without accidental shared pause');
  assert.equal(await observer.evaluate(() => document.querySelector('audio').paused), true, 'Observing client must never play audio');
  assert.deepEqual(errors, []); assert.deepEqual(fixtureErrors, []);
  report.passed = true;
} catch (error) { report.failure = error.message; process.exitCode = 1; }
finally {
  report.elapsed_ms = Math.round(performance.now() - started); report.audio_requests = audioRequests; report.commands = commands;
  report.shared_state = { state: state.state, owner: state.active_device_id, revision: state.revision, track_id: state.track?.id };
  report.clients = {};
  for (const [name, page] of Object.entries(pages)) {
    report.clients[name] = await page.evaluate(() => ({
      paused: document.querySelector('audio')?.paused,
      position: document.querySelector('audio')?.currentTime,
      control: document.querySelector('.play-button')?.getAttribute('aria-label'),
      system_state: navigator.mediaSession?.playbackState,
      media_events: window.__mediaControls.events,
    })).catch(() => ({ unavailable: true }));
  }
  await browser?.close(); for (const response of subscribers) response.end(); for (const socket of sockets) socket.destroy();
  await new Promise(resolve => server.close(resolve));
  await fs.mkdir(path.dirname(output), { recursive: true }); await fs.writeFile(output, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ passed: report.passed, browser: engineName, checks: report.checks.length, elapsed_ms: report.elapsed_ms, failure: report.failure, report: output }));
}
