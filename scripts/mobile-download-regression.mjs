import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Run against a fresh production build. All media and credentials are local fixtures.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/mobile-download-regression.mjs [build-dir] [report.json]
const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const moduleURL = moduleName.startsWith('/') || moduleName.startsWith('.') ? pathToFileURL(path.resolve(moduleName)).href : moduleName;
const { chromium } = await import(moduleURL);
const build = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '../build'));
const output = path.resolve(process.argv[3] ?? '/tmp/codec-mobile-download-regression.json');
const audioCacheName = 'codec-audio-downloads-v1';
const sampleRate = 22050, seconds = 90, wave = Buffer.alloc(44 + sampleRate * seconds * 2);
wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8); wave.writeUInt32LE(16, 16);
wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22); wave.writeUInt32LE(sampleRate, 24); wave.writeUInt32LE(sampleRate * 2, 28);
wave.writeUInt16LE(2, 32); wave.writeUInt16LE(16, 34); wave.write('data', 36); wave.writeUInt32LE(wave.length - 44, 40);
for (let i = 0; i < sampleRate * seconds; i++) wave.writeInt16LE(Math.round(Math.sin(i * 2 * Math.PI * 220 / sampleRate) * 500), 44 + i * 2);
let origin, tokens = 0, audioRequests = 0, reads = 0, workerGeneration = 1;
const subscribers = new Set();
const track = { id: 'fixture-song', path: 'loud://track/fixture-song', file_name: 'fixture.wav', title: 'Download continuity', artist: 'Local generated audio', album: 'Isolated test', duration_seconds: seconds, artwork_url: null, playlist_ids: [], is_liked: false, fingerprint: 'fixture-song', added_at: 1700000000, size_bytes: wave.length };
const ref = { id: track.id, path: track.path, fingerprint: track.fingerprint };
const library = { root_path: 'loud://fixture', scanned_at: 1700000000, tracks: [track], playlists: [], artists: [], albums: [], stats: { trackCount: 1, playlistCount: 0, likedCount: 0, artistCount: 1, albumCount: 1, durationSeconds: seconds } };
let state = { schema: 'loud.playback.v2', revision: 1, active_device_id: 'probe-browser', state: 'playing', track: ref, context: { playback_source: [ref], playback_index: 0, queued_tracks: [], play_history: [], shuffle: false, repeat: 'off' }, clock: { position_seconds: 10, started_at_ms: Date.now(), updated_at_ms: Date.now() }, volume: 0, server_time_ms: Date.now() };
const snapshot = () => ({ ...state, server_time_ms: Date.now() });
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, origin ?? 'http://127.0.0.1');
    const json = (value, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/health') return json({ ok: true, schema: 'loud.sync.v1', playback_schema: 'loud.playback.v2', server_id: 'isolated-download-test' });
    if (url.pathname === '/api/v1/library') return json(library);
    if (url.pathname === '/api/v1/auth/stream-token') return json({ token: `stream_fixture_${++tokens}`, expires_at: Math.floor(Date.now() / 1000) + 900 }, 201);
    if (url.pathname === '/api/v2/playback/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
      res.write(': fixture\n\n'); subscribers.add(res); req.on('close', () => subscribers.delete(res)); return;
    }
    if (url.pathname === '/api/v2/playback') { reads++; return json(snapshot()); }
    if (url.pathname.includes('/audio')) {
      audioRequests++;
      let start = 0, end = wave.length - 1;
      const range = /bytes=(\d+)-(\d*)/.exec(req.headers.range ?? '');
      if (range) { start = Number(range[1]); if (range[2]) end = Math.min(Number(range[2]), end); }
      const headers = { 'Content-Type': 'audio/wav', 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store', 'Content-Length': end - start + 1 };
      if (range) headers['Content-Range'] = `bytes ${start}-${end}/${wave.length}`;
      res.writeHead(range ? 206 : 200, headers); res.end(wave.subarray(start, end + 1)); return;
    }
    if (url.pathname.includes('/playback/devices')) return json(req.method === 'GET' ? [{ device_id: 'probe-browser', name: 'Isolated browser', updated_at: Date.now() }] : {});
    if (url.pathname === '/api/v2/playback/commands') {
      let body = ''; for await (const chunk of req) body += chunk;
      const command = JSON.parse(body), now = Date.now();
      state = { ...state, revision: state.revision + 1, ...(command.track ? { track: command.track } : {}), ...(command.context ? { context: command.context } : {}), state: command.kind === 'pause' ? 'paused' : 'playing', clock: { position_seconds: command.position_seconds ?? state.clock.position_seconds, started_at_ms: command.kind === 'pause' ? null : now, updated_at_ms: now } };
      return json(snapshot());
    }
    if (url.pathname.startsWith('/api/')) return json([]);
    const name = path.resolve(build, '.' + (url.pathname === '/' ? '/index.html' : decodeURIComponent(url.pathname)));
    if (!name.startsWith(build + path.sep)) { res.writeHead(403).end(); return; }
    let data = await fs.readFile(name);
    if (url.pathname === '/service-worker.js') { console.log(`Serving fixture service-worker generation ${workerGeneration}`); data = Buffer.concat([data, Buffer.from(`\n// Isolated upgrade generation ${workerGeneration}\n`)]); }
    res.writeHead(200, { 'Content-Type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ttf': 'font/ttf', '.woff2': 'font/woff2' })[path.extname(name)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' }); res.end(data);
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_BROWSER_PATH, args: ['--autoplay-policy=no-user-gesture-required'] });
const context = await browser.newContext({ viewport: { width: 402, height: 874 }, isMobile: true, hasTouch: true, serviceWorkers: 'allow' });
await context.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
await context.addInitScript(() => {
  localStorage.setItem('codec.syncServer', location.origin);
  localStorage.setItem('codec.syncToken', 'fixture-token');
  localStorage.setItem('codec.deviceId', 'probe-browser');
  window.__media = []; window.__polls = [];
  const proto = HTMLMediaElement.prototype;
  for (const name of ['load', 'play', 'pause']) { const original = proto[name]; proto[name] = function (...args) { window.__media.push({ op: name, time: this.currentTime }); return original.apply(this, args); }; }
  const descriptor = Object.getOwnPropertyDescriptor(proto, 'currentTime');
  Object.defineProperty(proto, 'currentTime', { ...descriptor, set(value) { window.__media.push({ op: 'seek', from: descriptor.get.call(this), to: value }); descriptor.set.call(this, value); } });
  const interval = window.setInterval;
  window.setInterval = function (fn, delay, ...args) { if (delay === 30000) window.__polls.push(() => fn(...args)); return interval(fn, delay, ...args); };
  for (const name of ['loadstart', 'emptied', 'waiting', 'stalled', 'playing', 'seeking', 'seeked', 'error']) document.addEventListener(name, event => { if (event.target instanceof HTMLMediaElement) window.__media.push({ op: `event:${name}`, time: event.target.currentTime }); }, true);
});
const page = await context.newPage(), errors = [], requests = [];
page.on('pageerror', error => errors.push(error.message));
page.on('request', request => { if (/\/audio|\/auth\/stream-token/.test(request.url())) requests.push({ url: request.url().replace(/access_token=[^&]+/, 'access_token=REDACTED'), method: request.method() }); });
const report = { build, origin, errors, phases: [], checks: [] };
async function capture(name) {
  console.log(`Phase: ${name}`);
  const phase = { name, tokens, audioRequests, reads, requests: [...requests], ...await page.evaluate(() => { const audio = document.querySelector('audio'); return { calls: [...window.__media], time: audio?.currentTime, paused: audio?.paused, source: audio?.currentSrc, polls: window.__polls.length }; }) };
  report.phases.push(phase); return phase;
}
async function cacheKeys() { return page.evaluate(async name => (await (await caches.open(name)).keys()).map(request => request.url), audioCacheName); }
async function openPlayer() { await page.getByRole('button', { name: `Open Now Playing: ${track.title}` }).click(); }
function noInterruption(phase) {
  assert.equal(phase.calls.filter(call => ['load', 'seek', 'pause', 'event:emptied', 'event:waiting'].includes(call.op)).length, 0, `${phase.name}: no reload, seek, pause or buffering`);
  assert.equal(phase.paused, false, `${phase.name}: keeps playing`);
}
try {
  await page.goto(origin);
  await page.waitForFunction(() => document.querySelector('audio')?.currentTime > 10 && document.querySelector('audio')?.paused === false);
  await page.evaluate(async () => { await navigator.serviceWorker.ready; if (!navigator.serviceWorker.controller) await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true })); });
  await page.waitForTimeout(250);
  const initial = await capture('initial HTTP playback');
  assert(initial.source.startsWith(origin), 'Starts with real HTTP streaming');
  await openPlayer();
  await page.evaluate(() => { window.__media = []; });
  await page.getByRole('button', { name: 'Download track', exact: true }).click();
  await page.getByRole('button', { name: 'Remove download', exact: true }).waitFor();
  const savedKeys = await cacheKeys();
  assert.equal(savedKeys.length, 1, 'Download UI writes one complete audio cache entry');
  assert(savedKeys[0].startsWith('https://codec-download.invalid/v1/'), 'Stored under synthetic key');
  assert(!savedKeys[0].includes('token') && !savedKeys[0].includes('/audio'), 'No stream URL or access token in cache key');
  for (let i = 0; i < 3; i++) { await page.evaluate(() => window.__polls.forEach(fn => fn())); await page.waitForTimeout(250); }
  const saved = await capture('download completes during HTTP playback and three sync polls');
  noInterruption(saved); assert.equal(saved.source, initial.source, 'Finishing download must retain current HTTP source');
  assert.equal(saved.audioRequests, initial.audioRequests + 1, 'Only the explicit full download adds an audio request');
  report.checks.push('download and polling preserve active HTTP audio');

  await page.evaluate(async () => { await (await caches.open('codec-app-stale-fixture')).put('/obsolete', new Response('old')); await (await caches.open('unrelated-feature-fixture')).put('/keep', new Response('keep')); });
  workerGeneration++;
  await page.evaluate(async () => {
    const registration = await navigator.serviceWorker.ready;
    const changed = new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true }));
    await Promise.race([
      // Production registration also changes the script query on each build.
      (async () => {
        const next = await navigator.serviceWorker.register('/service-worker.js?fixtureUpgrade=2', { scope: '/', updateViaCache: 'none' });
        await changed;
        const worker = next.active;
        if (worker.state !== 'activated') await new Promise(resolve => worker.addEventListener('statechange', () => { if (worker.state === 'activated') resolve(); }));
      })(),
      new Promise((_, reject) => setTimeout(() => reject(new Error(`Service worker upgrade timed out: active=${registration.active?.state} waiting=${registration.waiting?.state} installing=${registration.installing?.state}`)), 15000))
    ]);
  });
  for (let retry = 0; retry < 50 && await page.evaluate(async () => (await caches.keys()).includes('codec-app-stale-fixture')); retry++) await page.waitForTimeout(100);
  const names = await page.evaluate(() => caches.keys()); console.log('Caches after worker upgrade:', names);
  assert(!names.includes('codec-app-stale-fixture'), 'Upgrade cleans obsolete shell caches');
  assert(names.includes('unrelated-feature-fixture'), 'Upgrade preserves other features');
  assert.deepEqual(await cacheKeys(), savedKeys, 'Real service-worker activation preserves downloaded audio');
  report.checks.push('real service-worker upgrade preserves downloads and unrelated caches');

  await context.setOffline(true);
  for (const response of subscribers) response.end();
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.getByRole('navigation', { name: 'Mobile navigation' }).getByRole('button', { name: 'Library', exact: true }).click();
  await page.getByRole('button', { name: /^Downloaded\s+1$/ }).click();
  const song = page.getByRole('button', { name: `Play ${track.title}`, exact: true });
  await song.waitFor();
  // Startup probes may fail offline. Local playback itself must need neither a stream token nor HTTP audio.
  await page.waitForTimeout(250); requests.length = 0;
  await page.evaluate(() => { window.__media = []; });
  await song.click();
  await page.waitForFunction(() => document.querySelector('audio')?.currentSrc.startsWith('blob:') && document.querySelector('audio')?.paused === false);
  const offlineStart = await capture('offline shell reload and local playback');
  await page.waitForTimeout(700);
  const offline = await capture('offline audio advances');
  assert(offline.time > offlineStart.time + 0.3, 'Real audio decoder advances while offline');
  assert.equal(offline.requests.length, 0, 'Playing cached audio requests no stream token or HTTP media');
  assert.equal(offline.audioRequests, saved.audioRequests, 'No server audio request after download');
  report.checks.push('offline reload hydrates cached library and plays Blob audio without token or media requests');

  await openPlayer();
  await page.evaluate(() => { window.__media = []; });
  await page.getByRole('button', { name: 'Remove download', exact: true }).click();
  await page.getByRole('button', { name: 'Download track', exact: true }).waitFor();
  await page.waitForTimeout(700);
  const removed = await capture('remove active download');
  noInterruption(removed);
  assert.equal(removed.source, offline.source, 'Removal retains active Blob URL');
  assert(removed.time > offline.time + 0.3, 'Deleting cached file does not stop its decoder');
  assert.equal((await cacheKeys()).length, 0, 'Removal actually deletes persistent audio');
  assert.equal(removed.requests.length, 0, 'Removal does not request a network fallback');
  report.checks.push('removing a playing download preserves its Blob source and audio continuity');
  assert.equal(errors.length, 0, 'No uncaught browser errors');
  report.passed = true;
} catch (error) {
  report.passed = false; report.failure = error.stack;
  report.body = await page.locator('body').innerText().catch(() => '');
  await page.screenshot({ path: output.replace(/\.json$/, '') + '-failure.png' }).catch(() => {});
  throw error;
} finally {
  await fs.mkdir(path.dirname(output), { recursive: true });
  await fs.writeFile(output, JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ passed: report.passed, checks: report.checks, errors, report: output }, null, 2));
  await browser.close(); for (const response of subscribers) response.end(); await new Promise(resolve => server.close(resolve));
}
