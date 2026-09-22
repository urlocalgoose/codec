#!/usr/bin/env node
// Isolated real-browser playback-source regression. All artwork, music,
// credentials, devices, and playlists below are synthetic fixtures.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/playing-playlist-regression.mjs \
//   --build-dir build --browser webkit --themes graphite,paper --viewports 390,1440 --output-dir /tmp/codec-playing-playlist
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1]);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const build = path.resolve(args.get('build-dir') ?? path.join(repo, 'build'));
const output = path.resolve(args.get('output-dir') ?? path.join(os.tmpdir(), 'codec-playing-playlist'));
const moduleName = args.get('playwright-module') ?? process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const playwright = await import(moduleName.startsWith('/') ? pathToFileURL(moduleName).href : moduleName);
const browserName = args.get('browser') ?? 'webkit';
assert(['webkit', 'chromium'].includes(browserName), 'Use --browser webkit or chromium');
const widths = (args.get('viewports') ?? '390').split(',').map(Number);
const themes = (args.get('themes') ?? 'graphite,paper').split(',');
await fs.access(path.join(build, 'index.html'));
await fs.mkdir(output, { recursive: true });

// A minute of quiet generated tone keeps actual HTML audio playback observable.
const wave = Buffer.alloc(44 + 16000 * 60 * 2);
wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8);
wave.writeUInt32LE(16, 16); wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22);
wave.writeUInt32LE(16000, 24); wave.writeUInt32LE(32000, 28); wave.writeUInt16LE(2, 32); wave.writeUInt16LE(16, 34);
wave.write('data', 36); wave.writeUInt32LE(wave.length - 44, 40);
for (let i = 0; i < 16000 * 60; i++) wave.writeInt16LE(Math.round(Math.sin(i * Math.PI * 2 * 220 / 16000) * 300), 44 + i * 2);

let origin, fixture;
const subscribers = new Set();
const event = (type, data) => {
  for (const response of subscribers) response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
};
function makeFixture() {
  const tracks = ['Blue Hour', 'Afterglow', 'Open Road'].map((title, i) => ({
    id: `fixture-${i}`, fingerprint: `fixture-${i}`, path: `loud://track/fixture-${i}`, file_name: `fixture-${i}.wav`,
    title, artist: 'Synthetic fixture', album: title, duration_seconds: 60, artwork_url: `${origin}/api/fixture/artwork/${i}`,
    playlist_ids: i === 0 ? ['night', 'morning'] : i === 1 ? ['night'] : ['morning'],
    is_liked: false, added_at: 1700000000 + i, size_bytes: wave.length
  }));
  const playlists = [
    { id: 'night', name: 'Night Drive', track_ids: [tracks[0].id, tracks[1].id], artwork_url: `${origin}/api/fixture/artwork/night`, is_liked: false },
    { id: 'morning', name: 'Morning Mix', track_ids: [tracks[0].id, tracks[2].id], artwork_url: `${origin}/api/fixture/artwork/morning`, is_liked: false }
  ];
  const ref = track => ({ id: track.id, path: track.path, fingerprint: track.fingerprint });
  const now = Date.now();
  return {
    tracks, ref, commands: [], libraryReads: 0, audioRequests: 0,
    library: { root_path: 'loud://fixture', scanned_at: 1700000000, tracks, playlists, artists: [], albums: [],
      stats: { trackCount: 3, playlistCount: 2, likedCount: 0, artistCount: 1, albumCount: 3, durationSeconds: 180 } },
    state: { schema: 'loud.playback.v2', revision: 1, active_device_id: 'fixture-phone', state: 'playing', track: ref(tracks[0]),
      context: { playlist_id: 'morning', playback_source: [tracks[0], tracks[2]].map(ref), playback_index: 0,
        queued_tracks: [], play_history: [], shuffle: false, repeat: 'off' },
      clock: { position_seconds: 12, started_at_ms: now, stopped_at_ms: null, updated_at_ms: now }, volume: 0.05, server_time_ms: now }
  };
}
function publishState(update) {
  fixture.state = { ...fixture.state, ...update, revision: fixture.state.revision + 1, server_time_ms: Date.now() };
  event('playback_state', { playback_state: fixture.state });
}
const server = http.createServer(async (request, response) => {
  try {
    const pathname = new URL(request.url, origin ?? 'http://127.0.0.1').pathname;
    const json = (value, status = 200) => { response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); response.end(JSON.stringify(value)); };
    if (pathname === '/health') return json({ ok: true, schema: 'loud.sync.v1', playback_schema: 'loud.playback.v2', server_id: 'playlist-fixture' });
    if (pathname === '/api/v1/auth/stream-token') return json({ token: 'synthetic-only', expires_at: Date.now() / 1000 + 900 });
    if (pathname === '/api/v1/library') { fixture.libraryReads++; return json(fixture.library); }
    if (pathname === '/api/v2/playback') return json({ ...fixture.state, server_time_ms: Date.now() });
    if (pathname === '/api/v2/playback/events') {
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
      subscribers.add(response); request.on('close', () => subscribers.delete(response));
      response.write(`event: playback_state\ndata: ${JSON.stringify({ type: 'playback_state', playback_state: fixture.state })}\n\n`);
      return;
    }
    if (pathname.includes('/devices')) return json(request.method === 'GET' ? [
      { device_id: 'fixture-phone', name: 'Fixture phone', updated_at: Date.now() },
      { device_id: 'fixture-browser', name: 'This browser', updated_at: Date.now() }
    ] : {});
    if (pathname === '/api/v2/playback/commands') {
      let body = ''; for await (const chunk of request) body += chunk;
      const command = JSON.parse(body); fixture.commands.push(command);
      const previous = fixture.state;
      const context = command.context ?? previous.context;
      const state = command.kind === 'pause' ? 'paused' : command.kind === 'play' ? 'playing' : previous.state;
      const active = ['play', 'pause', 'transfer'].includes(command.kind) ? command.target_device_id ?? command.device_id : previous.active_device_id;
      const now = Date.now();
      publishState({ track: command.track ?? previous.track, context, state, active_device_id: active,
        clock: { position_seconds: command.position_seconds ?? previous.clock.position_seconds,
          started_at_ms: state === 'playing' ? now : null, stopped_at_ms: state === 'paused' ? now : null, updated_at_ms: now } });
      return json(fixture.state);
    }
    if (pathname.startsWith('/api/fixture/artwork/')) {
      const key = pathname.split('/').at(-1), morning = key === 'morning' || key === '2';
      const color = morning ? '#efa748' : '#3555bb', background = morning ? '#1b3131' : '#122238';
      response.writeHead(200, { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'private, max-age=600' });
      return response.end(`<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512"><rect width="512" height="512" fill="${background}"/><circle cx="256" cy="220" r="154" fill="${color}"/><path d="M0 385 512 245V512H0Z" fill="#ef6849"/><path d="M0 437 512 309V512H0Z" fill="${background}"/><text x="36" y="64" font-family="sans-serif" font-size="25" letter-spacing="6" fill="#fff">SYNTHETIC</text><text x="36" y="475" font-family="sans-serif" font-size="29" fill="#fff">${morning ? 'MORNING MIX' : 'NIGHT DRIVE'}</text></svg>`);
    }
    if (pathname.endsWith('/audio')) {
      fixture.audioRequests++;
      const range = /bytes=(\d+)-(\d*)/.exec(request.headers.range ?? '');
      const start = range ? Number(range[1]) : 0, end = range?.[2] ? Math.min(Number(range[2]), wave.length - 1) : wave.length - 1;
      const headers = { 'Content-Type': 'audio/wav', 'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1 };
      if (range) headers['Content-Range'] = `bytes ${start}-${end}/${wave.length}`;
      response.writeHead(range ? 206 : 200, headers); return response.end(wave.subarray(start, end + 1));
    }
    if (pathname.startsWith('/api/')) return json([]);
    const filename = path.resolve(build, `.${pathname === '/' ? '/index.html' : decodeURIComponent(pathname)}`);
    if (!filename.startsWith(build + path.sep)) return response.writeHead(403).end();
    const content = await fs.readFile(filename);
    response.writeHead(200, { 'Content-Type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' })[path.extname(filename)] ?? 'application/octet-stream' });
    response.end(content);
  } catch (error) {
    if (!response.headersSent) response.writeHead(500);
    response.end(String(error));
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
const report = { browser: browserName, fixture: 'Synthetic playlists, artwork, devices and generated audio. No personal library or live server used.', scenarios: [] };
let browser;
async function until(condition, message, timeout = 8000) {
  const deadline = Date.now() + timeout;
  while (!await condition()) { assert(Date.now() < deadline, message); await new Promise(resolve => setTimeout(resolve, 25)); }
}
try {
  browser = await playwright[browserName].launch({ headless: true, ...(browserName === 'chromium' ? { executablePath: args.get('browser-path') ?? process.env.PLAYWRIGHT_BROWSER_PATH } : {}) });
  for (const width of widths) for (const theme of themes) {
    fixture = makeFixture();
    const mobile = width <= 980;
    const scenario = { width, theme, checks: [], screenshots: [], errors: [] };
    report.scenarios.push(scenario);
    const context = await browser.newContext({ viewport: { width, height: mobile ? 844 : 960 }, deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile, serviceWorkers: 'block' });
    await context.addInitScript(theme => {
      localStorage.setItem('codec.theme', theme); localStorage.setItem('codec.syncServer', location.origin);
      localStorage.setItem('codec.syncToken', 'synthetic-only'); localStorage.setItem('codec.deviceId', 'fixture-browser');
      window.__fixtureMedia = [];
      for (const name of ['play', 'pause', 'load']) {
        const original = HTMLMediaElement.prototype[name];
        HTMLMediaElement.prototype[name] = function (...args) { window.__fixtureMedia.push(name); return original.apply(this, args); };
      }
    }, theme);
    const page = await context.newPage(); page.setDefaultTimeout(8000);
    page.on('pageerror', error => scenario.errors.push(error.message));
    await page.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
    const row = page.locator('.home-playing-source');
    const home = async () => {
      const navigation = mobile ? page.getByRole('navigation', { name: 'Mobile navigation' }) : page.locator('.sidebar');
      await navigation.getByRole('button', { name: 'Home', exact: true }).click();
      await page.locator('.home-view').waitFor();
    };
    const songs = async () => {
      if (mobile) {
        await page.getByRole('navigation', { name: 'Mobile navigation' }).getByRole('button', { name: 'Library', exact: true }).click();
        if (await page.locator('.mobile-library').count() === 0) await page.locator('.mobile-toolbar').getByRole('button', { name: 'Library', exact: true }).click();
        await page.locator('.mobile-library-group').getByRole('button', { name: /^Songs/ }).click();
      } else await page.locator('.sidebar').getByRole('button', { name: 'All Songs', exact: true }).click();
    };
    const shot = async name => {
      const filename = `${width}-${theme}-${name}.png`;
      await page.screenshot({ path: path.join(output, filename), animations: 'disabled' }); scenario.screenshots.push(filename);
    };
    const assertOrigin = async (name, state = 'Playing') => {
      await until(async () => await row.getAttribute('aria-label') === `${state} from ${name}. Open playlist`, `Missing ${state} playlist ${name}`);
    };
    const refreshLibrary = async () => {
      const reads = fixture.libraryReads; event('library', {});
      await until(() => fixture.libraryReads > reads, 'Library change was not refreshed');
    };
    try {
      await page.goto(origin); await page.locator('.home-view').waitFor();
      await assertOrigin('Morning Mix');
      await until(() => subscribers.size > 0, 'Live event stream did not connect');
      await until(() => row.locator('img').evaluate(image => image.complete && image.naturalWidth > 0), 'Playlist cover did not load');
      const coverPixel = await row.locator('img').evaluate(image => {
        const canvas = document.createElement('canvas'); canvas.width = canvas.height = 512;
        const drawing = canvas.getContext('2d'); drawing.drawImage(image, 0, 0, 512, 512);
        return [...drawing.getImageData(256, 128, 1, 1).data];
      });
      assert.deepEqual(coverPixel, [239, 167, 72, 255], 'Rendered source cover must be Morning Mix, including when cached as a blob URL');
      assert.equal(fixture.audioRequests, 0, 'Viewing phone playback must not stream duplicate audio');
      scenario.checks.push('Remote phone snapshot shows the explicit Morning Mix source although the song also belongs to Night Drive');
      await shot('playing-from-phone');

      const initialContext = fixture.state.context;
      publishState({ context: { ...initialContext, playlist_id: 'night', playback_source: fixture.tracks.slice(0, 2).map(fixture.ref) } });
      await assertOrigin('Night Drive');
      publishState({ context: initialContext }); await assertOrigin('Morning Mix');
      scenario.checks.push('Live source changes update even when the current song is identical');

      const commandsBefore = fixture.commands.length, mediaBefore = await page.evaluate(() => [...window.__fixtureMedia]);
      await row.click();
      await until(async () => await page.locator('.app-shell').getAttribute('data-view') === 'morning', 'Source row opened the wrong playlist');
      assert.equal(fixture.commands.length, commandsBefore, 'Opening a playlist must not send playback commands');
      assert.deepEqual(await page.evaluate(() => window.__fixtureMedia), mediaBefore, 'Opening source must not touch audio');
      assert.equal(fixture.audioRequests, 0);
      scenario.checks.push('Source row opens the exact playlist without playback commands or audio reloads');
      await home();

      publishState({ state: 'paused', clock: { position_seconds: 12, started_at_ms: null, stopped_at_ms: Date.now(), updated_at_ms: Date.now() } });
      await assertOrigin('Morning Mix', 'Paused');
      await shot('paused-from-phone');
      fixture.library.playlists[1].name = 'Morning Mix · Renamed'; await refreshLibrary();
      await assertOrigin('Morning Mix · Renamed', 'Paused');
      scenario.checks.push('Live pause and playlist rename update the Home row');

      const morning = fixture.library.playlists.pop(); await refreshLibrary();
      await until(async () => await row.count() === 0, 'Deleted playlist origin should disappear');
      fixture.library.playlists.push(morning); await refreshLibrary();
      await assertOrigin('Morning Mix · Renamed', 'Paused');
      const knownContext = fixture.state.context;
      const { playlist_id: ignored, ...unknownContext } = knownContext;
      publishState({ context: unknownContext });
      await until(async () => await row.count() === 0, 'Legacy context without provenance must not infer a playlist');
      publishState({ context: { ...knownContext, playlist_id: 'missing-playlist' } });
      await until(async () => await row.count() === 0, 'Unknown ID must not show the previous playlist');
      scenario.checks.push('Deleted, missing and legacy unknown sources hide without guessing from song membership');

      publishState({ active_device_id: 'fixture-browser', context: knownContext });
      await assertOrigin('Morning Mix · Renamed', 'Paused');
      await page.locator('.home-playlist-card').filter({ hasText: 'Night Drive' }).click();
      await page.locator('.list-actions').getByRole('button', { name: 'Play', exact: true }).click();
      await until(() => fixture.commands.some(command => command.kind === 'play' && command.context?.playlist_id === 'night'), 'Playlist Play did not send explicit origin');
      await page.waitForFunction(() => document.querySelector('audio')?.paused === false);
      await home(); await assertOrigin('Night Drive');
      assert.equal(fixture.state.context.playlist_id, 'night');
      scenario.checks.push('Starting a playlist sends its explicit ID and plays actual generated audio in this browser');

      const audioBefore = await page.locator('audio').evaluate(audio => audio.currentTime);
      const operationsBefore = await page.evaluate(() => [...window.__fixtureMedia]);
      const requestsBefore = fixture.audioRequests, commandCountBefore = fixture.commands.length;
      await row.click(); await home(); await assertOrigin('Night Drive');
      await page.waitForFunction(before => document.querySelector('audio').currentTime > before + 0.1, audioBefore);
      assert.deepEqual(await page.evaluate(() => window.__fixtureMedia), operationsBefore);
      assert.equal(fixture.audioRequests, requestsBefore);
      assert.equal(fixture.commands.length, commandCountBefore);
      scenario.checks.push('Opening and returning from the current playlist keeps local audio advancing with no reload or command');
      await shot('playing-here');

      await songs();
      const beforeQueue = fixture.commands.length;
      if (mobile) {
        // The native-style rows expose actions through a context menu; their
        // separate More button is a keyboard-only accessibility affordance.
        await page.getByRole('button', { name: 'Play Open Road', exact: true }).click({ button: 'right' });
        await page.getByRole('button', { name: 'Play Last', exact: true }).click();
      } else await page.getByRole('button', { name: 'Add Open Road to queue', exact: true }).click();
      await until(() => fixture.commands.slice(beforeQueue).some(command => command.kind === 'set_queue' && command.context?.playlist_id === 'night' && command.context.queued_tracks.some(track => track.id === 'fixture-2')), 'Manual queue insertion lost source playlist');
      await home(); await assertOrigin('Night Drive');
      scenario.checks.push('Queuing a song from outside the playlist sends and preserves the original source ID');

      await songs();
      const beforeGeneric = fixture.commands.length;
      await page.locator('.list-actions').getByRole('button', { name: 'Play', exact: true }).click();
      await until(() => fixture.commands.slice(beforeGeneric).some(command => command.kind === 'play' && command.context && command.context.playlist_id == null), 'Whole-library playback did not clear playlist provenance');
      await home(); await until(async () => await row.count() === 0, 'Whole-library start retained the old playlist');
      scenario.checks.push('Explicit whole-library playback clears provenance even when songs also belong to playlists');
      assert.deepEqual(scenario.errors, []);
      scenario.passed = true;
    } catch (error) {
      scenario.error = error.stack; await shot('failure'); throw error;
    } finally {
      await context.close();
      for (const response of subscribers) response.end(); subscribers.clear();
    }
  }
  report.passed = true;
} finally {
  await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
  await browser?.close();
  for (const response of subscribers) response.end();
  server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
}
