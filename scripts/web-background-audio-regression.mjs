import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';

// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/web-background-audio-regression.mjs [build-dir] [report.json]
// Optional: PLAYWRIGHT_BROWSER=webkit, PLAYWRIGHT_BROWSER_PATH=/path/to/browser.
// Real generated audio, AudioContext, FFT, canvas, and SSE; no production data.
// Visibility/page lifecycle events and a headphone-style pause are simulated.
// Only an absent AudioSession API gets a stub. This is NOT an iPhone screen-lock
// or Bluetooth hardware test; physical Safari/PWA lock/unlock still needs testing.
const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const moduleURL = /^[./]/.test(moduleName) ? pathToFileURL(path.resolve(moduleName)).href : moduleName;
const engines = await import(moduleURL);
const engineName = process.env.PLAYWRIGHT_BROWSER ?? 'chromium';
assert(['chromium', 'webkit'].includes(engineName), 'Use Chromium or WebKit');
const build = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '../build'));
const output = path.resolve(process.argv[3] ?? '/tmp/codec-web-background-audio-regression.json');
await fs.access(path.join(build, 'index.html'));

const sampleRate = 22050, seconds = 90;
const wave = Buffer.alloc(44 + sampleRate * seconds * 2);
wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8);
wave.writeUInt32LE(16, 16); wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22);
wave.writeUInt32LE(sampleRate, 24); wave.writeUInt32LE(sampleRate * 2, 28);
wave.writeUInt16LE(2, 32); wave.writeUInt16LE(16, 34); wave.write('data', 36);
wave.writeUInt32LE(wave.length - 44, 40);
// Low amplitude keeps WebKit's real output quiet. Chromium also mutes its sink,
// not the media element, so the analyser still receives decoded samples.
for (let i = 0; i < sampleRate * seconds; i++) {
  wave.writeInt16LE(Math.round(Math.sin(i * 2 * Math.PI * 440 / sampleRate) * 96), 44 + i * 2);
}
const speakerID = 'background-speaker', observerID = 'background-observer', remoteID = 'native-fixture';
const track = { id: 'background-tone', path: 'loud://track/background-tone', fingerprint: 'background-tone',
  file_name: 'tone.wav', title: 'Background audio fixture', artist: 'Generated local tone', album: 'Lifecycle regression',
  duration_seconds: seconds, artwork_url: null, playlist_ids: [], is_liked: false, added_at: 1700000000, size_bytes: wave.length };
const ref = { id: track.id, path: track.path, fingerprint: track.fingerprint };
const library = { root_path: 'loud://background-fixture', scanned_at: 1700000000, tracks: [track], playlists: [], artists: [], albums: [],
  stats: { trackCount: 1, playlistCount: 0, likedCount: 0, artistCount: 1, albumCount: 1, durationSeconds: seconds } };
function clock(at, playing) {
  const now = Date.now();
  return { position_seconds: at, started_at_ms: playing ? now : null, stopped_at_ms: playing ? null : now, updated_at_ms: now };
}
let state = { schema: 'loud.playback.v2', revision: 1, active_device_id: speakerID, state: 'paused', track: ref,
  context: { playback_source: [ref], playback_index: 0, queued_tracks: [], play_history: [], shuffle: false, repeat: 'off' },
  clock: clock(5, false), volume: 1, server_time_ms: Date.now() };
let origin, audioRequests = 0, tokenCount = 0;
const subscribers = new Set(), sockets = new Set(), commands = [], errors = [], fixtureErrors = [], externalRequests = [];
const report = { passed: false, build, browser: engineName, viewport: '390x844',
  simulated_lifecycle: true, physical_iphone_lock_tested: false,
  limitation: 'Desktop browser lifecycle simulation cannot verify iOS process suspension, screen lock, interruptions, or Bluetooth hardware.',
  checks: [], phases: [], errors, fixtureErrors, externalRequests };
const snapshot = () => ({ ...state, server_time_ms: Date.now() });
const position = () => state.clock.position_seconds + (state.state === 'playing' && state.clock.started_at_ms ? (Date.now() - state.clock.started_at_ms) / 1000 : 0);
function broadcast() {
  for (const response of subscribers) response.write(`event: playback_state\ndata: ${JSON.stringify({ type: 'playback_state', playback_state: snapshot() })}\n\n`);
}
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, origin ?? 'http://127.0.0.1');
    const json = (value, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/health') return json({ ok: true, schema: 'loud.sync.v1', playback_schema: 'loud.playback.v2', server_id: 'isolated-background-audio' });
    if (url.pathname === '/api/v1/library') return json(library);
    if (url.pathname === '/api/v1/auth/stream-token') return json({ token: `stream_fixture_${++tokenCount}`, expires_at: Math.floor(Date.now() / 1000) + 900 }, 201);
    if (url.pathname === '/api/v2/playback/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
      res.write(': fixture\n\n'); subscribers.add(res); req.on('close', () => subscribers.delete(res)); return;
    }
    if (url.pathname === '/api/v2/playback') return json(snapshot());
    if (url.pathname.includes('/playback/devices')) return json(req.method === 'GET'
      ? [speakerID, observerID, remoteID].map(id => ({ device_id: id, name: id, updated_at: Date.now() })) : {});
    if (url.pathname === '/api/v2/playback/commands') {
      let body = ''; for await (const chunk of req) body += chunk;
      const command = JSON.parse(body);
      commands.push({ ...command, expected_revision: req.headers['if-match'] ?? null });
      if (req.headers['if-match'] && Number(String(req.headers['if-match']).replaceAll('"', '')) !== state.revision) return json({ error: 'Fixture revision conflict' }, 409);
      assert(['play', 'pause', 'seek', 'transfer', 'set_queue', 'set_shuffle', 'set_repeat', 'volume'].includes(command.kind), `Unexpected command ${command.kind}`);
      const at = command.position_seconds ?? position();
      const nextStatus = command.kind === 'play' ? 'playing' : command.kind === 'pause' ? 'paused' : state.state;
      state = { ...state, revision: state.revision + 1, state: nextStatus,
        active_device_id: command.target_device_id ?? command.device_id ?? state.active_device_id,
        track: command.track ?? state.track, context: command.context ?? state.context, clock: clock(at, nextStatus === 'playing') };
      json(snapshot()); broadcast(); return;
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
  } catch (error) {
    if (req.url.startsWith('/api/')) fixtureErrors.push(error.message);
    if (!res.headersSent) res.writeHead(404);
    res.end();
  }
});
server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
let browser;
const pages = {};
const started = performance.now();
function passed(name, detail = {}) { report.checks.push({ name, passed: true, ...detail }); }
async function waitUntil(condition, message, timeout = 7000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (await condition()) return; await new Promise(resolve => setTimeout(resolve, 25)); }
  assert.fail(message);
}
async function capture(page, name) {
  const local = await page.evaluate(() => {
    const probe = window.__backgroundAudio;
    const audio = document.querySelector('audio');
    return { now: performance.now(), time: audio?.currentTime, paused: audio?.paused, source: audio?.currentSrc,
      duration: audio?.duration, buffered: audio ? Array.from({ length: audio.buffered.length }, (_, i) => [audio.buffered.start(i), audio.buffered.end(i)]) : [],
      session: navigator.audioSession.type, initialSession: probe.initialSession, audioSessionMode: probe.audioSessionMode,
      sessionState: navigator.audioSession.state ?? null, readyState: audio?.readyState,
      graphTimes: probe.graphs.map(context => context.currentTime),
      hidden: document.hidden, samples: probe.samples, peak: probe.peak, draws: probe.draws,
      rendererFrames: probe.rendererFrames, graphs: probe.graphs.map(context => context.state),
      calls: [...probe.calls], instrumentationErrors: [...probe.errors] };
  });
  const result = { name, ...local, commands: commands.length, audioRequests };
  report.phases.push(result); return result;
}
async function visibility(page, hidden) {
  await page.evaluate(hidden => {
    window.__backgroundAudio.hidden = hidden;
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new PageTransitionEvent(hidden ? 'pagehide' : 'pageshow', { persisted: true }));
  }, hidden);
}
function preserveTransport(before, after, label, { allowIdlePause = false } = {}) {
  const calls = after.calls.slice(before.calls.length);
  assert.deepEqual(calls.filter(call => ['media.play', 'media.pause', 'media.load', 'media.seek', 'event.emptied', 'event.loadstart', 'event.pause'].includes(call.op)
    && !(allowIdlePause && call.op === 'media.pause' && call.paused === true)), [], `${label}: no media restart, pause, source reload, or seek`);
  assert.equal(after.source, before.source, `${label}: retain the audio source`);
  assert.equal(after.audioRequests, before.audioRequests, `${label}: do not fetch audio again`);
  assert.equal(after.commands, before.commands, `${label}: no playback command or remote pause`);
}
try {
  browser = await engines[engineName].launch({ headless: true,
    ...(process.env.PLAYWRIGHT_BROWSER_PATH ? { executablePath: process.env.PLAYWRIGHT_BROWSER_PATH } : {}),
    ...(engineName === 'chromium' ? { args: ['--autoplay-policy=no-user-gesture-required', '--mute-audio'] } : {}) });
  async function client(device) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, serviceWorkers: 'block' });
    await context.addInitScript(({ device }) => {
      localStorage.setItem('codec.syncServer', location.origin);
      localStorage.setItem('codec.syncToken', 'fixture-token'); localStorage.setItem('codec.deviceId', device);
      const probe = window.__backgroundAudio = { hidden: false, graphs: [], calls: [], handlers: {}, errors: [], samples: 0, peak: 0, draws: 0, rendererFrames: 0 };
      const record = (op, extra = {}) => probe.calls.push({ op, at: performance.now(), session: navigator.audioSession?.type, hidden: probe.hidden, ...extra });
      if (!navigator.audioSession || typeof navigator.audioSession.type !== 'string') {
        let type = 'ambient';
        const stub = { get type() { return type; }, set type(value) { type = value; record('session.type', { value }); } };
        Object.defineProperty(navigator, 'audioSession', { configurable: true, value: stub });
        probe.audioSessionMode = 'stub: browser lacks AudioSession';
      } else probe.audioSessionMode = 'native API, unchanged';
      probe.initialSession = navigator.audioSession.type;
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => probe.hidden });
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => probe.hidden ? 'hidden' : 'visible' });
      const OriginalContext = window.AudioContext;
      window.AudioContext = new Proxy(OriginalContext, { construct(target, args) {
        record('graph.construct');
        const graph = Reflect.construct(target, args); probe.graphs.push(graph); return graph;
      } });
      for (const method of ['resume', 'suspend', 'close']) {
        const original = OriginalContext.prototype[method];
        OriginalContext.prototype[method] = function (...args) {
          record(`graph.${method}`, { state: this.state }); return original.apply(this, args);
        };
      }
      const originalFrequency = AnalyserNode.prototype.getByteFrequencyData;
      AnalyserNode.prototype.getByteFrequencyData = function (values) {
        const result = originalFrequency.call(this, values); probe.samples++;
        for (const value of values) probe.peak = Math.max(probe.peak, value);
        return result;
      };
      // Identify the real renderer callback by its canvas work, then count every
      // subsequent invocation, including idle frames that draw no new columns.
      const rendererCallbacks = new WeakSet();
      let activeFrame = null;
      const originalRAF = window.requestAnimationFrame.bind(window);
      window.requestAnimationFrame = callback => originalRAF(time => {
        const parentFrame = activeFrame;
        const frame = activeFrame = { drewVisualizer: false };
        try { callback(time); }
        finally {
          if (frame.drewVisualizer) rendererCallbacks.add(callback);
          if (rendererCallbacks.has(callback)) probe.rendererFrames++;
          activeFrame = parentFrame;
        }
      });
      for (const method of ['fillRect', 'drawImage']) {
        const original = CanvasRenderingContext2D.prototype[method];
        CanvasRenderingContext2D.prototype[method] = function (...args) {
          if (this.canvas.closest('.visualizer-view')) { probe.draws++; if (activeFrame) activeFrame.drewVisualizer = true; }
          return original.apply(this, args);
        };
      }
      for (const method of ['play', 'pause', 'load']) {
        const original = HTMLMediaElement.prototype[method];
        HTMLMediaElement.prototype[method] = function (...args) {
          record(`media.${method}`, { time: this.currentTime, paused: this.paused }); return original.apply(this, args);
        };
      }
      const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'currentTime');
      if (!descriptor?.set) probe.errors.push('Cannot observe native media currentTime setter');
      else Object.defineProperty(HTMLMediaElement.prototype, 'currentTime', { ...descriptor, set(value) {
        record('media.seek', { from: descriptor.get.call(this), to: value }); descriptor.set.call(this, value);
      } });
      for (const type of ['play', 'pause', 'playing', 'loadstart', 'emptied', 'error']) document.addEventListener(type, event => {
        if (event.target instanceof HTMLMediaElement) record(`event.${type}`, { time: event.target.currentTime, paused: event.target.paused });
      }, true);
      if (navigator.mediaSession) {
        const original = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
        navigator.mediaSession.setActionHandler = (action, callback) => {
          const result = original(action, callback); probe.handlers[action] = callback; return result;
        };
      }
    }, { device });
    const page = await context.newPage(); page.setDefaultTimeout(10000);
    page.on('pageerror', error => errors.push({ device, message: error.message }));
    await page.route('**/*', route => {
      if (new URL(route.request().url()).origin === origin) return route.continue();
      externalRequests.push(route.request().url()); return route.abort();
    });
    await page.goto(origin, { waitUntil: 'domcontentloaded' });
    await page.locator('.mobile-mini-player').waitFor();
    return page;
  }
  const speaker = pages.speaker = await client(speakerID);
  const observer = pages.observer = await client(observerID);
  await waitUntil(() => subscribers.size === 2, 'Both isolated clients must receive SSE');
  const initialObserver = await capture(observer, 'remote-only client startup');
  assert.equal(initialObserver.session, initialObserver.initialSession, 'Remote-only client must retain the browser session type');
  assert.deepEqual(initialObserver.graphs, [], 'Remote-only client must not create an audio graph');
  assert(!initialObserver.calls.some(call => call.op === 'media.play' || (call.op === 'session.type' && call.value === 'playback')), 'Remote-only client must never claim playback');
  assert.equal(commands.length, 0, 'Restoring paused shared state must send no transport commands');
  passed('remote-only startup does not claim a session or graph');

  await speaker.locator('.mobile-mini-player').getByRole('button', { name: 'Play', exact: true }).click();
  await waitUntil(() => state.state === 'playing', 'Explicit Play must reach shared state');
  await speaker.waitForFunction(() => {
    const audio = document.querySelector('audio');
    return audio && !audio.paused && audio.currentTime > 5.15;
  });
  await speaker.getByRole('button', { name: 'Visualizer', exact: true }).click();
  await speaker.waitForFunction(() => {
    const probe = window.__backgroundAudio;
    return probe.graphs.length === 1 && probe.graphs[0].state === 'running' && probe.samples > 3 && probe.peak > 0 && probe.rendererFrames > 2;
  });
  const sessionReady = await capture(speaker, 'local playback session ordering');
  const firstPlay = sessionReady.calls.find(call => call.op === 'media.play');
  const firstGraph = sessionReady.calls.find(call => call.op === 'graph.construct');
  assert(firstPlay && firstGraph, 'Exercise actual media playback and graph creation');
  assert.equal(firstPlay.session, 'playback', 'AudioSession must be playback BEFORE the first element.play()');
  assert.equal(firstGraph.session, 'playback', 'AudioSession must be playback BEFORE AudioContext construction');
  assert.equal(sessionReady.graphs.length, 1);
  passed('playback session precedes first real play and graph creation', { audioSessionMode: sessionReady.audioSessionMode, initialType: sessionReady.initialSession, fftPeak: sessionReady.peak });
  // Chromium can finish its initial seek/range request after playback begins.
  // Start network continuity measurements only when that real buffer is ready.
  // Session-policy assertions above intentionally do not depend on buffering.
  await speaker.waitForFunction(() => {
    const audio = document.querySelector('audio');
    return audio.buffered.length && audio.buffered.end(audio.buffered.length - 1) > audio.duration - 0.05;
  });
  await speaker.waitForTimeout(150);
  const playing = await capture(speaker, 'buffered local playback and real spectrum');

  await visibility(speaker, true);
  await speaker.waitForTimeout(100);
  const hidden = await capture(speaker, 'hidden, settled');
  // WebKit coalesces HTMLMediaElement time reads more than its AudioContext
  // clock. Observe both over 1.5 seconds, without introducing a polling RAF.
  await speaker.waitForTimeout(1500);
  await speaker.waitForFunction(time => document.querySelector('audio').currentTime > time + 0.05, hidden.time, { timeout: 2000, polling: 100 });
  const hiddenLater = await capture(speaker, 'hidden, still playing');
  assert.equal(hiddenLater.samples, hidden.samples, 'Hidden page stops FFT sampling');
  assert.equal(hiddenLater.draws, hidden.draws, 'Hidden page stops visualizer canvas drawing');
  assert.equal(hiddenLater.rendererFrames, hidden.rendererFrames, 'Hidden page stops the renderer RAF loop, including idle frames');
  assert.equal(hiddenLater.paused, false); assert.equal(hiddenLater.graphs[0], 'running');
  assert(hiddenLater.time > hidden.time + 0.05, 'Real media must advance while synthetically hidden');
  assert(hiddenLater.graphTimes[0] > hidden.graphTimes[0] + 1, 'The real output context must keep processing while hidden');
  await visibility(speaker, false);
  await speaker.waitForFunction(samples => window.__backgroundAudio.samples > samples, hiddenLater.samples);
  await speaker.waitForTimeout(220);
  const visible = await capture(speaker, 'visible without interruption');
  preserveTransport(playing, visible, 'Normal hide/show');
  assert(visible.time >= playing.time && visible.time - playing.time < (visible.now - playing.now) / 1000 + 0.5, 'Hide/show must not jump the audio clock');
  assert.equal(visible.graphs[0], 'running'); assert.equal(visible.session, 'playback');
  passed('hidden FFT and renderer stop while audio continues; wake has no pause, reload, seek, or remote command');

  await visibility(speaker, true);
  await speaker.evaluate(() => window.__backgroundAudio.graphs[0].suspend());
  const suspended = await capture(speaker, 'simulated suspended context, element still playing');
  assert.equal(suspended.paused, false); assert.equal(suspended.graphs[0], 'suspended');
  await visibility(speaker, false);
  await speaker.waitForFunction(() => window.__backgroundAudio.graphs[0].state === 'running');
  await speaker.waitForTimeout(250);
  const recovered = await capture(speaker, 'foreground resumes local output context');
  preserveTransport(suspended, recovered, 'Context recovery');
  assert(recovered.calls.slice(suspended.calls.length).some(call => call.op === 'graph.resume'), 'Foreground must resume the suspended local output context');
  assert(recovered.time > suspended.time, 'Decoded media advances after context recovery');
  assert.equal(recovered.session, 'playback');
  passed('foreground resumes a real suspended local AudioContext without restarting the element');

  await visibility(speaker, true);
  const beforePauseCommands = commands.length;
  const pauseMethod = await speaker.evaluate(() => {
    const pause = window.__backgroundAudio.handlers.pause;
    if (typeof pause === 'function') { pause({ action: 'pause' }); return 'registered MediaSession pause callback'; }
    document.querySelector('audio').pause(); return 'real media pause event; browser lacks MediaSession pause';
  });
  await waitUntil(() => state.state === 'paused' && commands.length === beforePauseCommands + 1, 'Explicit headphone-style pause must sync exactly once');
  assert.equal(commands.at(-1).kind, 'pause'); assert.equal(commands.at(-1).target_device_id, speakerID);
  await speaker.evaluate(() => window.__backgroundAudio.graphs[0].suspend());
  await speaker.waitForTimeout(100);
  const intentionallyPaused = await capture(speaker, 'explicit pause, hidden and suspended');
  assert.equal(intentionallyPaused.paused, true);
  await visibility(speaker, false);
  await speaker.waitForTimeout(400);
  const stayedPaused = await capture(speaker, 'explicit pause survives foreground');
  preserveTransport(intentionallyPaused, stayedPaused, 'Explicit pause wake');
  assert.equal(stayedPaused.paused, true); assert.equal(stayedPaused.graphs[0], 'suspended');
  assert(Math.abs(stayedPaused.time - intentionallyPaused.time) < 0.05, 'An intentional pause must retain its position');
  assert(!stayedPaused.calls.slice(intentionallyPaused.calls.length).some(call => call.op === 'graph.resume'), 'Foreground must not resume a deliberately paused session');
  passed('explicit headphone-style pause remains paused across wake', { pauseMethod });

  await speaker.locator('.mobile-mini-player').getByRole('button', { name: 'Play', exact: true }).click();
  await waitUntil(() => state.state === 'playing', 'User can resume after an intentional pause');
  await speaker.waitForFunction(() => !document.querySelector('audio').paused && window.__backgroundAudio.graphs[0].state === 'running');
  const beforeTransferCommands = commands.length;
  state = { ...state, revision: state.revision + 1, active_device_id: remoteID, clock: clock(position(), true) }; broadcast();
  await speaker.waitForFunction(() => document.querySelector('audio').paused && window.__backgroundAudio.graphs[0].state === 'suspended'
    && navigator.audioSession.type === window.__backgroundAudio.initialSession);
  await speaker.waitForTimeout(100);
  const transferred = await capture(speaker, 'ownership transferred away');
  assert.equal(commands.length, beforeTransferCommands, 'Applying a transfer must not echo a pause');
  assert.equal(transferred.session, transferred.initialSession, 'Transfer restores the exact previous AudioSession type');
  await visibility(speaker, true); await visibility(speaker, false);
  await speaker.waitForTimeout(350);
  const remoteWake = await capture(speaker, 'foreground while native owns playback');
  // Sync may defensively pause an already-idle element when reading remote
  // state. It must never emit an actual pause event or touch the remote owner.
  preserveTransport(transferred, remoteWake, 'Remote-owner wake', { allowIdlePause: true });
  assert.equal(remoteWake.session, remoteWake.initialSession); assert.equal(remoteWake.graphs[0], 'suspended');
  assert.equal(remoteWake.samples, transferred.samples); assert.equal(remoteWake.rendererFrames, transferred.rendererFrames);
  assert(!remoteWake.calls.slice(transferred.calls.length).some(call => call.op === 'graph.resume' || (call.op === 'session.type' && call.value === 'playback')), 'Remote-owner wake cannot claim playback or resume local output');
  assert.equal(state.active_device_id, remoteID); assert.equal(state.state, 'playing');
  passed('transfer restores previous session type; remote-owner wake leaves local output idle');

  const finalObserver = await capture(observer, 'remote-only client after all transitions');
  assert.equal(finalObserver.session, finalObserver.initialSession); assert.equal(finalObserver.paused, true);
  assert.deepEqual(finalObserver.graphs, []);
  assert(!finalObserver.calls.some(call => call.op === 'media.play' || (call.op === 'session.type' && call.value === 'playback')), 'Observer never claims local playback during remote changes');
  assert.equal(remoteWake.graphs.length, 1, 'Every lifecycle transition retains the same audio graph');
  assert.deepEqual(errors, []); assert.deepEqual(fixtureErrors, []); assert.deepEqual(externalRequests, []);
  for (const phase of report.phases) assert.deepEqual(phase.instrumentationErrors, []);
  report.passed = true;
} catch (error) { report.failure = error.stack ?? error.message; process.exitCode = 1; }
finally {
  report.elapsed_ms = Math.round(performance.now() - started); report.audio_requests = audioRequests; report.commands = commands;
  report.shared_state = { state: state.state, owner: state.active_device_id, revision: state.revision };
  for (const [name, page] of Object.entries(pages)) {
    await capture(page, `${name} final diagnostics`).catch(() => undefined);
  }
  await browser?.close(); for (const response of subscribers) response.end(); for (const socket of sockets) socket.destroy();
  await new Promise(resolve => server.close(resolve));
  await fs.mkdir(path.dirname(output), { recursive: true }); await fs.writeFile(output, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ passed: report.passed, browser: engineName, checks: report.checks.length, elapsed_ms: report.elapsed_ms,
    failure: report.failure, physical_iphone_lock_tested: false, report: output }));
}
