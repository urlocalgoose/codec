#!/usr/bin/env node
// Usage and runtime configuration: scripts/mobile-regression.md
// Selective profiling: --profile-only true --viewports 390 --themes graphite
// Focused regression: --interaction-only, --song-gesture-only, --viewport-only, or --download-only true, with
// --viewports 390 --themes graphite. Run viewport mode in browser + standalone.
// Desktop footer actions: --desktop-player-only true --viewports 1024,1440 --themes graphite.
// Optional --display-mode standalone simulates navigator.standalone for app
// mode detection. It does not reproduce iOS Safari chrome or OS safe areas.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1]);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.resolve(args.get('output-dir') ?? process.env.CODEC_TEST_OUTPUT ?? path.join(os.tmpdir(), 'codec-mobile-regression'));
const moduleName = args.get('playwright-module') ?? process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const moduleURL = moduleName.startsWith('/') || moduleName.startsWith('.') ? pathToFileURL(path.resolve(moduleName)).href : moduleName;
let browserType;
const browserName = args.get('browser') ?? 'chromium';
if (!['chromium','webkit'].includes(browserName)) throw new Error('--browser must be chromium or webkit');
try { browserType = (await import(moduleURL))[browserName]; }
catch { throw new Error('Playwright is required. Set PLAYWRIGHT_MODULE to an installed playwright/index.mjs, or install playwright in your test environment. See scripts/mobile-regression.md.'); }

await fs.mkdir(output, { recursive: true });
let server;
let baseURL = args.get('base-url') ?? process.env.CODEC_TEST_URL;
if (!baseURL) {
  const build = path.resolve(args.get('build-dir') ?? path.join(repo, 'build'));
  await fs.access(path.join(build, 'index.html')).catch(() => { throw new Error('Missing web build. Run bun run build first.'); });
  const types = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.json': 'application/json' };
  server = http.createServer(async (request, response) => {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    const filename = path.resolve(build, `.${pathname === '/' ? '/index.html' : pathname}`);
    if (!filename.startsWith(`${build}${path.sep}`)) { response.writeHead(403).end(); return; }
    try {
      const data = await fs.readFile(filename);
      response.writeHead(200, { 'Content-Type': types[path.extname(filename)] ?? 'application/octet-stream' });
      response.end(data);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseURL = `http://127.0.0.1:${server.address().port}`;
}

const report = { baseURL, browser: browserName, startedAt: new Date().toISOString(), scenarios: [], failures: [] };
const browser = await browserType.launch({ headless: args.get('headed') !== 'true', ...(browserName === 'chromium' ? {executablePath: args.get('browser-path') ?? process.env.PLAYWRIGHT_BROWSER_PATH} : {}) });
const widths = (args.get('viewports') ?? '320,390,430,1024,1440').split(',').map(Number);
const themes = (args.get('themes') ?? 'oxide,paper').split(',');
const profileOnly = args.get('profile-only') === 'true';
const interactionOnly = args.get('interaction-only') === 'true';
const viewportOnly = args.get('viewport-only') === 'true';
const downloadOnly = args.get('download-only') === 'true';
const songGestureOnly = args.get('song-gesture-only') === 'true';
const desktopPlayerOnly = args.get('desktop-player-only') === 'true';
assert([profileOnly, interactionOnly, viewportOnly, downloadOnly, songGestureOnly, desktopPlayerOnly].filter(Boolean).length <= 1, 'Select at most one focused mode');
const displayMode = args.get('display-mode') ?? 'browser';
assert(['browser', 'standalone'].includes(displayMode), '--display-mode must be browser or standalone');
report.configuration = { buildDirectory: args.get('build-dir') ?? path.join(repo, 'build'), profileOnly, interactionOnly, viewportOnly, downloadOnly, songGestureOnly, desktopPlayerOnly, displayMode,
  fixtureTracks: 2000, fixtureArtworkVariants: 4, realIPhone: false };

async function waitUntil(condition, message, timeout = 6000) {
  const deadline = Date.now() + timeout;
  while (!(await condition())) {
    assert(Date.now() < deadline, message);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

function fixtures(origin) {
  const tracks = Array.from({ length: 2000 }, (_, i) => ({
    id: `sample-${i}`, path: `loud://track/sample-${i}`, file_name: `sample-${i}.mp3`,
    title: `Sample track ${String(i + 1).padStart(4, '0')}`, artist: `Sample artist ${i % 4 + 1}`,
    album: `Sample album ${i % 6 + 1}`, duration_seconds: 180,
    artwork_url: `${origin}/api/fixture/artwork/${i % 4}`, playlist_ids: [], is_liked: false,
    fingerprint: `sample-${i}`, added_at: 1700000000 + i, size_bytes: 1024
  }));
  const playlists = [
    { id: 'fixture-cover', name: 'Weekend Records', track_ids: tracks.slice(0, 14).map((t) => t.id), artwork_url: `${origin}/api/fixture/artwork/custom`, is_liked: false },
    { id: 'fixture-collage', name: 'Late Night Mix', track_ids: tracks.slice(0, 20).map((t) => t.id), artwork_url: null, is_liked: false }
  ];
  const updateMemberships = () => {
    for (const track of tracks) track.playlist_ids = playlists.filter(playlist => playlist.track_ids.includes(track.id)).map(playlist => playlist.id);
  };
  updateMemberships();
  const library = { root_path: 'loud://fixture', scanned_at: 1700000000, tracks, playlists, artists: [], albums: [], stats: {
    trackCount: tracks.length, playlistCount: playlists.length, likedCount: 0, artistCount: 4, albumCount: 6, durationSeconds: tracks.length * 180
  } };
  const ref = (track) => ({ id: track.id, path: track.path, fingerprint: track.fingerprint });
  let state = { schema: 'loud.playback.v2', revision: 1, active_device_id: 'fixture-other-device', state: 'paused', track: ref(tracks[0]),
    context: { playback_source: tracks.map(ref), playback_index: 0, queued_tracks: [], play_history: [], shuffle: false, repeat: 'off' },
    clock: { position_seconds: 42, started_at_ms: null, updated_at_ms: Date.now() }, volume: 0.5, server_time_ms: Date.now() };
  const commands = [];
  const mutations = [];
  const wave = Buffer.alloc(44 + 1600);
  wave.write('RIFF',0); wave.writeUInt32LE(wave.length-8,4); wave.write('WAVEfmt ',8);
  wave.writeUInt32LE(16,16); wave.writeUInt16LE(1,20); wave.writeUInt16LE(1,22);
  wave.writeUInt32LE(8000,24); wave.writeUInt32LE(16000,28); wave.writeUInt16LE(2,32); wave.writeUInt16LE(16,34);
  wave.write('data',36); wave.writeUInt32LE(1600,40);
  let audioRequests = 0;
  let audioMode = 'valid', audioGate, releaseAudio, activeAudio = 0, maxActiveAudio = 0;
  let failPlaylistDelete = false;
  let artworkRequests = 0;
  let libraryReads = 0;
  let received = 0;
  let release;
  let gate;
  return {
    tracks, library, commands, mutations,
    get audioRequests() { return audioRequests; },
    get maxActiveAudio() { return maxActiveAudio; },
    setAudioResponse(mode) { audioMode = mode; },
    setPlaylistDeleteFailure(value) { failPlaylistDelete = value; },
    holdAudioDownloads() { audioGate = new Promise(resolve => { releaseAudio = resolve; }); },
    releaseAudioDownloads() { releaseAudio?.(); audioGate = undefined; },
    get artworkRequests() { return artworkRequests; },
    get libraryReads() { return libraryReads; },
    get state() { return state; },
    clearPlayback() {
      const previous = state;
      state = { ...state, revision: state.revision + 1, active_device_id: null, track: null, state: 'paused',
        context: { ...state.context, playback_source: [], playback_index: 0, queued_tracks: [], play_history: [] },
        clock: { position_seconds: 0, started_at_ms: null, updated_at_ms: Date.now() }, server_time_ms: Date.now() };
      return () => { state = { ...previous, revision: state.revision + 1, server_time_ms: Date.now() }; };
    },
    advanceSource() { state = { ...state, revision: state.revision + 1, track: ref(tracks[1]), context: { ...state.context, playback_index: 1 }, server_time_ms: Date.now() }; },
    seedDesktopQueue() { state = { ...state, revision: state.revision + 1, context: { ...state.context, queued_tracks: [tracks[1], tracks[1], ...tracks.slice(100, 1300)].map(ref) } }; },
    get receivedCommands() { return received; },
    holdNextCommand() { gate = new Promise((resolve) => { release = resolve; }); },
    releaseCommand() { release?.(); gate = undefined; },
    seedLargeManualQueue() { state = { ...state, revision: state.revision + 1, context: { ...state.context, queued_tracks: tracks.slice(100, 1300).map(ref) } }; },
    async handle(route) {
      const request = route.request();
      const url = new URL(request.url());
      const pathname = url.pathname;
      if (url.origin !== origin) return route.abort('blockedbyclient');
      if (pathname === '/health') return route.fulfill({ json: { ok: true, schema: 'loud.sync.v1', playback_schema: 'loud.playback.v2', server_id: 'fixture' } });
      if (!pathname.startsWith('/api/')) return route.continue();
      if (pathname.startsWith('/api/fixture/artwork/')) {
        artworkRequests += 1;
        const color = ['#ed6237', '#5c82b7', '#cca34b', '#68966b'][Number(pathname.split('/').at(-1)) % 4] ?? '#a76ac0';
        return route.fulfill({ contentType: 'image/svg+xml', body: `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><rect width="256" height="256" fill="${color}"/><circle cx="128" cy="128" r="88" fill="#202323"/><circle cx="128" cy="128" r="27" fill="${color}"/><circle cx="128" cy="128" r="7" fill="#eeeecc"/></svg>` });
      }
      if (pathname === '/api/v1/library') { libraryReads++; return route.fulfill({ json: library }); }
      if (pathname === '/api/v1/auth/stream-token') return route.fulfill({ json: { token: 'stream_fixture', expires_at: Math.floor(Date.now() / 1000) + 600 } });
      if (pathname === '/api/v2/playback/events') return route.fulfill({ contentType: 'text/event-stream', body: ': fixture\n\n' });
      if (pathname === '/api/v2/playback') return route.fulfill({ json: state });
      if (pathname === '/api/v2/playback/commands') {
        received += 1;
        const held = gate;
        if (held) await held;
        const command = request.postDataJSON();
        const expected = request.headers()['if-match'];
        const status = expected && expected !== `"${state.revision}"` ? 409 : 200;
        commands.push({ kind: command.kind, expected, serverRevision: state.revision, status, queue: command.context?.queued_tracks?.map((track) => track.id) });
        if (status === 409) return route.fulfill({ status, json: { error: 'Playback revision conflict' } });
        state = { ...state, revision: state.revision + 1, track: command.track ?? state.track, context: command.context ?? state.context, server_time_ms: Date.now() };
        return route.fulfill({ json: state });
      }
      if (pathname.includes('/playback/devices') || pathname === '/api/v1/aux') return route.fulfill({ json: [] });
      if (pathname.includes('/audio')) {
        audioRequests += 1; activeAudio++; maxActiveAudio = Math.max(maxActiveAudio, activeAudio);
        const mode = audioMode, gate = audioGate;
        try {
          if (gate) await gate;
          if (mode === 'html') return await route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Proxy sign-in</title>' });
          if (mode === 'empty') return await route.fulfill({ contentType: 'audio/wav', body: '' });
          if (mode === 'unavailable') return await route.fulfill({ status: 503, json: { error: 'Fixture server unavailable' } });
          return await route.fulfill({ contentType: 'audio/wav', body: wave, headers: { 'Content-Length': String(wave.length) } });
        } finally { activeAudio--; }
      }
      const likedMatch = pathname.match(/^\/api\/v1\/tracks\/([^/]+)\/liked$/);
      if (likedMatch && request.method() === 'PUT') {
        const track = tracks.find(track => track.fingerprint === decodeURIComponent(likedMatch[1]));
        if (!track) return route.fulfill({ status: 404, json: { error: 'Unknown fixture track' } });
        track.is_liked = request.postDataJSON().liked;
        library.stats.likedCount = tracks.filter(track => track.is_liked).length;
        mutations.push({ method: 'PUT', track: track.id, liked: track.is_liked, authenticated: request.headers().authorization === 'Bearer fixture-owner-token' });
        return route.fulfill({ json: {} });
      }
      const playlistMatch = pathname.match(/^\/api\/v1\/playlists\/([^/]+)\/tracks(?:\/([^/]+))?$/);
      if (playlistMatch) {
        const playlist = playlists.find(p => p.id === decodeURIComponent(playlistMatch[1]));
        if (!playlist) return route.fulfill({status:404,json:{error:'Unknown fixture playlist'}});
        const body = request.method() === 'DELETE' ? null : request.postDataJSON();
        mutations.push({method:request.method(),playlist:playlist.id,body,authenticated:request.headers().authorization === 'Bearer fixture-owner-token'});
        if (request.method() === 'PUT') playlist.track_ids = [...body.track_ids];
        else if (request.method() === 'POST') { const track = tracks.find(t=>t.fingerprint===body.fingerprint); if(track && !playlist.track_ids.includes(track.id))playlist.track_ids.push(track.id); }
        else if (request.method() === 'DELETE') playlist.track_ids = playlist.track_ids.filter(id=>id!==decodeURIComponent(playlistMatch[2]));
        updateMemberships();
        return route.fulfill({json:playlist});
      }
      const deletePlaylistMatch = pathname.match(/^\/api\/v1\/playlists\/([^/]+)$/);
      if (deletePlaylistMatch && request.method() === 'DELETE') {
        const id = decodeURIComponent(deletePlaylistMatch[1]);
        mutations.push({ method: 'DELETE', playlist: id, status: failPlaylistDelete ? 503 : 200 });
        if (failPlaylistDelete) return route.fulfill({ status: 503, json: { error: 'Fixture playlist delete unavailable' } });
        const index = playlists.findIndex(playlist => playlist.id === id);
        if (index < 0) return route.fulfill({ status: 404, json: { error: 'Unknown fixture playlist' } });
        playlists.splice(index, 1); library.stats.playlistCount = playlists.length;
        updateMemberships();
        return route.fulfill({ json: {} });
      }
      if(pathname.startsWith('/api/v1/aux/')) return route.fulfill({json:{code:'ABCD',guest_token:'fixture-guest'}});
      return route.fulfill({ json: {} });
    }
  };
}

async function listMetrics(page, selector = '.track-row', scrollSelector = '.content') {
  return page.evaluate(({ selector, scrollSelector }) => {
    const scroller = document.querySelector(scrollSelector);
    const rows = [...document.querySelectorAll(selector)];
    const viewport = scroller.getBoundingClientRect();
    const visible = rows.filter((row) => { const box = row.getBoundingClientRect(); return box.bottom > viewport.top && box.top < viewport.bottom && box.height > 0; });
    return { count: rows.length, scrollTop: scroller.scrollTop, first: rows[0]?.textContent?.trim(),
      firstVisible: visible[0]?.textContent?.trim(), visible: visible.length };
  }, { selector, scrollSelector });
}

try {
  for (const { width, theme } of widths.flatMap((width) => themes.map((theme) => ({ width, theme })))) {
    const mobile = width <= 980;
    const scenario = { width, theme, mobile, displayMode, screenshots: [], errors: [], consoleErrors: [], issues: [], checks: {} };
    report.scenarios.push(scenario);
    // Bundled WebKit's nonpersistent contexts discard CacheStorage on reload,
    // even on an empty page. Downloads need an isolated real profile to test
    // persistence; the profile is removed after this scenario.
    const profileDirectory = (downloadOnly || songGestureOnly) && browserName === 'webkit' ? await fs.mkdtemp(path.join(os.tmpdir(), 'codec-webkit-download-')) : null;
    const contextOptions = { viewport: { width, height: mobile ? 844 : 960 }, deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile, serviceWorkers: 'block' };
    const context = profileDirectory
      ? await browserType.launchPersistentContext(profileDirectory, { ...contextOptions, headless: args.get('headed') !== 'true' })
      : await browser.newContext(contextOptions);
    scenario.storageContext = profileDirectory ? 'isolated temporary persistent profile' : 'isolated nonpersistent context';
    await context.addInitScript(({ theme, displayMode, profileOnly, viewportOnly, downloadOnly, songGestureOnly, mobile }) => {
      localStorage.setItem('codec.theme', theme);
      localStorage.setItem('codec.syncServer', location.origin);
      localStorage.setItem('codec.deviceId', 'fixture-browser');
      if (!mobile) localStorage.setItem('codec.syncToken', 'fixture-owner-token');
      Object.defineProperty(navigator, 'standalone', { configurable: true, value: displayMode === 'standalone' });
      if (songGestureOnly) {
        window.__songGestureEvents = [];
        for (const type of ['pointerdown', 'pointerup', 'pointercancel', 'lostpointercapture', 'dragstart', 'click']) {
          document.addEventListener(type, event => {
            const element = event.target instanceof Element ? event.target : null;
            window.__songGestureEvents.push({ type, at: performance.now(), pointerType: event.pointerType, pointerId: event.pointerId,
              tag: element?.tagName, track: element?.closest('[data-track-id]')?.getAttribute('data-track-id'),
              label: element?.closest('button')?.getAttribute('aria-label') ?? element?.closest('button')?.textContent?.trim(), x: event.clientX, y: event.clientY });
            if (window.__songGestureEvents.length > 120) window.__songGestureEvents.shift();
          }, true);
        }
      }
      if (viewportOnly) {
        // Deliberately synthetic geometry: desktop WebKit does not provide
        // actual iPhone Safari chrome, OS keyboard, or home-indicator insets.
        const viewport = new EventTarget();
        Object.assign(viewport, { height: 844, width: innerWidth, offsetTop: 0, offsetLeft: 0, pageTop: 0, pageLeft: 0, scale: 1 });
        Object.defineProperty(window, 'visualViewport', { configurable: true, value: viewport });
        window.__setFixtureViewport = values => { Object.assign(viewport, values); viewport.dispatchEvent(new Event('resize')); };
      }
      if (downloadOnly) {
        window.__cacheKeyScans = 0;
        const keys = Cache.prototype.keys;
        Cache.prototype.keys = function (...args) { window.__cacheKeyScans++; return keys.apply(this, args); };
      }
      if (profileOnly) {
        const probe = window.__mobileProfile = { started: performance.now(), longTasks: [], longTaskSupported: PerformanceObserver.supportedEntryTypes.includes('longtask'),
          addedRows: 0, removedRows: 0, attributes: 0, imageSourceChanges: 0, textChanges: 0 };
        if (probe.longTaskSupported) new PerformanceObserver(list => {
          for (const entry of list.getEntries()) probe.longTasks.push({ start: entry.startTime, duration: entry.duration });
        }).observe({ type: 'longtask', buffered: true });
        new MutationObserver(records => {
          for (const record of records) {
            if (record.type === 'attributes') { probe.attributes++; if (record.target instanceof HTMLImageElement && record.attributeName === 'src') probe.imageSourceChanges++; }
            if (record.type === 'characterData') probe.textChanges++;
            for (const kind of ['added', 'removed']) for (const node of record[`${kind}Nodes`] ?? []) {
              if (node instanceof Element) probe[`${kind}Rows`] += Number(node.matches('.track-row,.mobile-queue-row')) + node.querySelectorAll('.track-row,.mobile-queue-row').length;
            }
          }
        }).observe(document, { childList: true, subtree: true, attributes: true, characterData: true });
      }
    }, { theme, displayMode, profileOnly, viewportOnly, downloadOnly, songGestureOnly, mobile });
    const fixture = fixtures(new URL(baseURL).origin);
    if (profileOnly || interactionOnly) fixture.seedLargeManualQueue();
    const page = await context.newPage();
    page.on('pageerror', (error) => scenario.errors.push(error.stack || error.message || String(error)));
    page.on('console', (message) => { if (message.type() === 'error') scenario.consoleErrors.push(message.text()); });
    await page.route('**/*', (route) => fixture.handle(route));
    page.setDefaultTimeout(8000);
    const shot = async (name) => {
      const filename = `${width}-${theme}-${name}.png`;
      await page.screenshot({ path: path.join(output, filename), animations: 'disabled' });
      scenario.screenshots.push(filename);
    };
    const mobileTab = async (name) => page.getByRole('navigation', { name: 'Mobile navigation' }).getByRole('button', { name, exact: true }).click();
    const openSongs = async () => {
      if (mobile) {
        await mobileTab('Library');
        // Tabs retain their navigation stack like SwiftUI. Return from a
        // restored collection to the Library root before selecting Songs.
        if (await page.locator('.mobile-library').count() === 0) {
          assert(!['home', 'search', 'visualizer'].includes(await page.locator('.app-shell').getAttribute('data-view')), 'Library tab should restore its previous collection');
          scenario.checks.tabRestoration = 'Library restores the previous collection';
          await page.locator('.mobile-toolbar').getByRole('button', { name: 'Library', exact: true }).click();
        }
        assert.equal(await page.locator('.queue-rail-row').count(), 0, 'Mobile must not render a hidden desktop queue');
        for (const selector of ['.mobile-toolbar h1', '.mobile-playlist-row strong']) {
          const colors = await page.locator(selector).first().evaluate((element) => {
            const probe = document.createElement('span');
            probe.style.color = 'var(--color-text)';
            element.appendChild(probe);
            const expected = getComputedStyle(probe).color;
            const actual = getComputedStyle(element).color;
            probe.remove();
            return { expected, actual };
          });
          assert.equal(colors.actual, colors.expected, `${selector} must use the active theme's text color`);
        }
        await page.locator('.mobile-library-group').getByRole('button', { name: /^Songs/ }).click();
      } else await page.getByRole('button', { name: 'All Songs', exact: true }).click();
      await page.locator('.track-row').first().waitFor();
    };
    const deepScroll = async (key, selector = '.track-row', scroller = '.content') => {
      await page.locator(scroller).evaluate((element) => { element.scrollTop = 10000; });
      await waitUntil(async () => (await listMetrics(page, selector, scroller)).visible > 0, `${key}: blank viewport after scrolling`);
      const metrics = await listMetrics(page, selector, scroller);
      assert(metrics.scrollTop > 9000, `${key}: fixture did not scroll deeply enough`);
      assert(metrics.count < 100, `${key}: ${metrics.count} rows mounted for a virtualized list`);
      assert(!metrics.firstVisible?.startsWith('Sample track 0001'), `${key}: still rendering the beginning of the list`);
      scenario.checks[key] = metrics;
      await shot(key);
    };
    const profile = async () => {
      assert(mobile, '--profile-only is a focused mobile fixture');
      const measures = scenario.profile = [];
      const geometry = () => page.evaluate(() => {
        const rect = selector => { const box = document.querySelector(selector)?.getBoundingClientRect(); return box ? { top: box.top, bottom: box.bottom, height: box.height } : null; };
        return { innerHeight, visualViewportHeight: visualViewport?.height, visualViewportOffset: visualViewport?.offsetTop,
          standalone: navigator.standalone, modeAttribute: document.documentElement.dataset.displayMode ?? document.querySelector('.app-shell')?.dataset.displayMode,
          shell: rect('.app-shell'), content: rect('.content'), mini: rect('.mobile-mini-player'), tabs: rect('.mobile-tab-bar') };
      });
      const collect = async (name, action = async () => {}) => {
        const artworkBefore = fixture.artworkRequests;
        const before = await page.evaluate(() => ({ ...window.__mobileProfile, now: performance.now() }));
        await action();
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        const metrics = await page.evaluate(before => {
          const p = window.__mobileProfile;
          const tasks = p.longTasks.filter(task => task.start >= before.now);
          return { completion_ms: performance.now() - before.now, elements: document.querySelectorAll('*').length,
            songRows: document.querySelectorAll('.track-row').length, queueRows: document.querySelectorAll('.mobile-queue-row').length,
            images: document.querySelectorAll('img').length, addedRows: p.addedRows - before.addedRows, removedRows: p.removedRows - before.removedRows,
            attributeChanges: p.attributes - before.attributes, textChanges: p.textChanges - before.textChanges, imageSourceChanges: p.imageSourceChanges - before.imageSourceChanges,
            longTaskSupported: p.longTaskSupported, longTaskCount: tasks.length, longTaskTotal_ms: tasks.reduce((sum, task) => sum + task.duration, 0),
            longestTask_ms: Math.max(0, ...tasks.map(task => task.duration)) };
        }, before);
        measures.push({ name, ...metrics, artworkRequests: fixture.artworkRequests - artworkBefore });
      };
      await collect('home settled');
      scenario.profileGeometry = [{ name: 'initial', ...await geometry() }];
      await collect('open 2000-song collection', openSongs);
      await collect('scroll songs to index ~100', async () => {
        await page.locator('.content').evaluate(element => { element.scrollTop = 10000; });
        await waitUntil(async () => (await listMetrics(page)).firstVisible?.includes('Sample track 0') && (await listMetrics(page)).scrollTop > 9000, 'Profile songs must scroll');
      });
      await collect('scroll songs to final row', async () => {
        await page.locator('.content').evaluate(element => { element.scrollTop = element.scrollHeight; });
        await page.getByRole('button', { name: 'Play Sample track 2000', exact: true }).waitFor();
      });
      scenario.profileLastRow = await page.getByRole('button', { name: 'Play Sample track 2000', exact: true }).evaluate(element => {
        const row = element.getBoundingClientRect(), mini = document.querySelector('.mobile-mini-player').getBoundingClientRect();
        return { rowBottom: row.bottom, miniTop: mini.top, clearance: mini.top - row.bottom };
      });
      await collect('open Now Playing', async () => {
        await page.getByRole('button', { name: /^Open Now Playing:/ }).click();
        await page.getByRole('dialog', { name: 'Now Playing', exact: true }).waitFor();
      });
      await collect('open 1200-manual + 1999-upcoming queue', async () => {
        await page.getByRole('dialog', { name: 'Now Playing', exact: true }).getByRole('button', { name: 'Queue', exact: true }).click();
        await page.locator('.native-queue-sheet [data-queue-group="manual"]').first().waitFor();
      });
      await shot('profile-queue');
      await collect('advance current track while queue open', async () => {
        fixture.advanceSource(); await page.evaluate(() => window.dispatchEvent(new Event('pageshow')));
        await page.locator('.native-queue-sheet .mobile-queue-row.current').getByText('Sample track 0002', { exact: true }).waitFor();
      });
      await collect('scroll large manual queue', async () => {
        await page.locator('.native-queue-sheet .mobile-sheet-body').evaluate(element => { element.scrollTop = 10000; });
        await waitUntil(async () => (await listMetrics(page, '.native-queue-sheet .mobile-queue-row', '.native-queue-sheet .mobile-sheet-body')).visible > 0, 'Profile queue must have visible rows');
      });
      await page.keyboard.press('Escape'); await page.getByRole('dialog', { name: 'Queue', exact: true }).waitFor({ state: 'detached' });
      await page.keyboard.press('Escape');
      for (const height of [700, 844]) {
        await page.setViewportSize({ width, height });
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        scenario.profileGeometry.push({ name: `viewport height ${height}`, ...await geometry() });
      }
      scenario.checks.selectiveProfile = 'Generated 2000-song fixture; timings include automation overhead and UI readiness plus two frames, not an FPS estimate.';
      assert.deepEqual(scenario.errors, [], 'Unhandled browser errors during profile');
      console.log(JSON.stringify({ width, theme, displayMode, profile: measures, geometry: scenario.profileGeometry, lastRow: scenario.profileLastRow }));
    };
    const nextFrames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const interactions = async () => {
      assert(mobile, '--interaction-only is a focused mobile fixture');
      scenario.simulation = 'Trusted browser mouse pointers exercise the shared swipe/reorder handlers; pointercancel is synthesized. This does not emulate iPhone touch scrolling physics.';
      await page.getByRole('button', { name: /^Open Now Playing:/ }).click();
      await page.getByRole('dialog', { name: 'Now Playing', exact: true }).getByRole('button', { name: 'Queue', exact: true }).click();
      const queue = page.getByRole('dialog', { name: 'Queue', exact: true });
      const first = () => queue.locator('[data-queue-group="manual"][data-queue-index="0"]');
      const content = queue.locator('.mobile-queue-content');
      const scroller = queue.locator('.mobile-sheet-body');
      await first().waitFor();
      const initialTrack = fixture.state.track.id;
      const initialOrder = fixture.state.context.queued_tracks.map(track => track.id);
      const beginSwipe = async () => {
        const box = await first().locator('.mobile-queue-play').boundingBox();
        const point = { x: box.x + box.width * .75, y: box.y + box.height / 2 };
        await page.mouse.move(point.x, point.y); await page.mouse.down();
        return point;
      };
      let point = await beginSwipe();
      await page.mouse.move(point.x - 55, point.y + 2, { steps: 5 });
      await waitUntil(async () => first().evaluate(row => {
        const content = row.querySelector('.mobile-queue-row-content') ?? row.querySelector('.mobile-queue-play');
        return row.classList.contains('queue-swiping') && new DOMMatrixReadOnly(getComputedStyle(content).transform).m41 < -20;
      }), 'Queue artwork and text must follow the swipe before pointerup');
      await page.mouse.move(point.x - 108, point.y + 2, { steps: 4 }); await page.mouse.up();
      await waitUntil(async () => first().evaluate(row => row.classList.contains('queue-swipe-open')), 'Left swipe must reveal Remove');
      await first().locator('.mobile-queue-play').dispatchEvent('click', { detail: 1 });
      await nextFrames();
      assert.equal(fixture.receivedCommands, 0, 'The click after a swipe must not play or remove anything');
      assert.deepEqual(fixture.state.context.queued_tracks.map(track => track.id), initialOrder);
      scenario.checks.liveSwipe = 'Artwork/text move during swipe; releasing exposes Remove; following click does not play or remove';

      // Close the open action, then lock the next gesture vertically before
      // taking it left. A scrolling gesture must never become a delete swipe.
      await page.evaluate(() => window.dispatchEvent(new Event('blur')));
      point = await beginSwipe();
      await page.mouse.move(point.x + 1, point.y + 35, { steps: 4 });
      await page.mouse.move(point.x - 110, point.y + 45, { steps: 5 }); await page.mouse.up();
      await first().locator('.mobile-queue-play').dispatchEvent('click', { detail: 1 });
      await nextFrames();
      assert.equal(await queue.locator('.queue-swipe-open').count(), 0, 'Vertical-first drag must not reveal Remove after changing direction');
      assert.equal(fixture.receivedCommands, 0, 'Vertical-first drag must not play the row');
      scenario.checks.verticalSwipeLock = 'Vertical-first gesture remains scrolling intent after moving sideways';

      point = await beginSwipe();
      await page.mouse.move(point.x - 70, point.y, { steps: 5 });
      await page.evaluate(() => window.dispatchEvent(new PointerEvent('pointercancel', { pointerId: 1, pointerType: 'mouse', isPrimary: true, bubbles: true })));
      await page.mouse.up();
      await first().locator('.mobile-queue-play').dispatchEvent('click', { detail: 1 });
      await nextFrames();
      assert.equal(await queue.locator('.queue-swipe-open,.queue-swiping').count(), 0, 'Cancelled swipe must restore the row');
      assert.equal(fixture.receivedCommands, 0, 'Cancelled swipe must not play or remove the row');
      scenario.checks.cancelledSwipe = 'Pointer cancellation resets swipe and suppresses its trailing click';

      if (browserName === 'chromium') {
        // CDP creates trusted touch events, including the browser's implicit
        // pointer capture and generated click. WebKit has no matching API.
        const touch = await context.newCDPSession(page);
        await page.evaluate(() => document.addEventListener('pointerdown', event => {
          if (event.pointerType === 'touch') window.__queueTouchPointer = event.pointerId;
        }, { once: true }));
        const box = await first().locator('.mobile-queue-play').boundingBox();
        const start = { x: box.x + box.width * .75, y: box.y + box.height / 2 };
        const dispatch = (type, x = start.x, y = start.y) => touch.send('Input.dispatchTouchEvent', {
          type, touchPoints: type === 'touchEnd' || type === 'touchCancel' ? [] : [{ x, y, id: 0, radiusX: 3, radiusY: 3 }]
        });
        await dispatch('touchStart');
        await dispatch('touchMove', start.x - 65, start.y + 2);
        await waitUntil(async () => first().evaluate(row => row.classList.contains('queue-swiping')), 'Trusted touch swipe must remain active after implicit capture moves to the persistent list');
        assert(await content.evaluate(element => element.hasPointerCapture(window.__queueTouchPointer)), 'Trusted swipe must transfer capture to the persistent list');
        await dispatch('touchMove', start.x - 110, start.y + 2); await dispatch('touchEnd');
        await waitUntil(async () => first().evaluate(row => row.classList.contains('queue-swipe-open')), 'Trusted touch must reveal Remove');
        assert.equal(fixture.receivedCommands, 0, 'Trusted touch release must not issue an accidental play');
        await page.evaluate(() => window.dispatchEvent(new Event('blur')));
        await dispatch('touchStart'); await dispatch('touchMove', start.x - 65, start.y); await dispatch('touchCancel');
        await nextFrames();
        assert.equal(await queue.locator('.queue-swiping,.queue-swipe-open').count(), 0, 'Trusted touch cancellation must close swipe');
        assert.equal(fixture.receivedCommands, 0, 'Trusted touch cancellation must not play or remove');
        await touch.detach();
        scenario.checks.trustedTouchCapture = 'CDP trusted touch transfers implicit capture, swipes without play, and resets on native pointer cancellation';
      }

      await queue.getByRole('button', { name: 'Edit', exact: true }).click();
      await first().locator('.queue-reorder-control').click();
      await first().locator('.queue-move-actions').waitFor();
      await first().getByRole('button', { name: 'Move Sample track 0101 down', exact: true }).click();
      await waitUntil(() => fixture.state.context.queued_tracks[1]?.id === initialOrder[0], 'Tap-handle Move Down must move exactly one row');
      assert.deepEqual(fixture.state.context.queued_tracks.slice(0, 3).map(track => track.id), [initialOrder[1], initialOrder[0], initialOrder[2]]);
      scenario.checks.tapMove = 'Tapping the handle exposes an explicit one-position move';

      const beforeDrag = fixture.state.context.queued_tracks.map(track => track.id);
      const commandsBeforeDrag = fixture.receivedCommands;
      const handle = await first().locator('.queue-reorder-control').boundingBox();
      const bounds = await scroller.boundingBox();
      await page.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2); await page.mouse.down();
      await page.mouse.move(handle.x + handle.width / 2, Math.min(bounds.y + bounds.height - 4, 838), { steps: 12 });
      await waitUntil(async () => scroller.evaluate(element => element.scrollTop > 1600), 'Holding a reorder at the bottom edge must autoscroll across virtual rows', 7000);
      const duringDrag = await scroller.evaluate(element => ({ scrollTop: element.scrollTop,
        mountedRows: element.querySelectorAll('.mobile-queue-row').length,
        firstMounted: Number(element.querySelector('[data-queue-group="manual"]')?.getAttribute('data-queue-index')) }));
      assert(duringDrag.firstMounted > 0, 'Edge reorder must survive the source row leaving the virtual window');
      assert(duringDrag.mountedRows < 100, 'Edge reorder must keep queue rendering bounded');
      await page.mouse.up();
      await waitUntil(() => fixture.receivedCommands > commandsBeforeDrag, 'Releasing after edge scrolling must commit a reorder');
      await waitUntil(() => fixture.commands.length === fixture.receivedCommands, 'Reorder must complete');
      const afterDrag = fixture.state.context.queued_tracks.map(track => track.id);
      const movedIndex = afterDrag.indexOf(beforeDrag[0]);
      assert(movedIndex > 10, 'The source row must move beyond its initial viewport');
      assert.deepEqual(afterDrag.filter(id => id !== beforeDrag[0]), beforeDrag.slice(1), 'Edge reorder must preserve every other queue entry in order');
      assert.equal(afterDrag.length, beforeDrag.length, 'Edge reorder must not remove or duplicate entries');
      assert.equal(fixture.state.track.id, initialTrack, 'Editing the queue must not change the playing song');
      assert.equal(fixture.audioRequests, 0, 'Queue editing for the remote owner must not stream locally');
      assert.equal(await content.evaluate(element => element.hasPointerCapture(1)), false, 'Reorder capture must be released');
      scenario.checks.edgeAutoscroll = { ...duringDrag, movedIndex, queueLength: afterDrag.length };
      await shot('interaction-queue-after-edge-move');

      // A remote queue replacement can arrive while a row is held at the
      // edge. The old gesture must stop instead of applying its stale index.
      await scroller.evaluate(element => { element.scrollTop = 0; });
      await first().waitFor();
      const nextHandle = await first().locator('.queue-reorder-control').boundingBox();
      const beforeCancelCommands = fixture.receivedCommands;
      await page.mouse.move(nextHandle.x + nextHandle.width / 2, nextHandle.y + nextHandle.height / 2); await page.mouse.down();
      await page.mouse.move(nextHandle.x + nextHandle.width / 2, Math.min(bounds.y + bounds.height - 4, 838), { steps: 10 });
      await waitUntil(async () => scroller.evaluate(element => element.scrollTop > 400), 'Cancellation fixture must first start real edge scrolling');
      await queue.locator('.queue-drag-preview').waitFor();
      fixture.seedLargeManualQueue();
      await page.evaluate(() => window.dispatchEvent(new Event('pageshow')));
      await queue.locator('.queue-drag-preview').waitFor({ state: 'detached' });
      const stoppedAt = await scroller.evaluate(element => element.scrollTop);
      await page.waitForTimeout(180);
      assert(Math.abs(await scroller.evaluate(element => element.scrollTop) - stoppedAt) < 2, 'Remote queue replacement must stop the edge-scroll animation');
      await page.mouse.up(); await nextFrames();
      assert.equal(fixture.receivedCommands, beforeCancelCommands, 'Trailing pointerup after queue replacement must not commit a stale reorder');
      assert.deepEqual(fixture.state.context.queued_tracks.map(track => track.id), initialOrder, 'Remote replacement must preserve the server queue exactly');
      assert.equal(await content.evaluate(element => element.hasPointerCapture(1)), false, 'Canceled reorder capture must be released');
      scenario.checks.remoteChangeCancelsDrag = 'Remote queue replacement removes the drag preview, stops edge scrolling, and suppresses stale pointerup reorder';
      await queue.locator('.mobile-sheet-trailing').getByRole('button', { name: 'Done', exact: true }).first().click();
      await scroller.evaluate(element => { element.scrollTop = 0; }); await first().waitFor();
      const removeBox = await first().locator('.mobile-queue-play').boundingBox();
      const removeQueue = fixture.state.context.queued_tracks.map(track => track.id), beforeRemoveCommands = fixture.receivedCommands;
      await page.mouse.move(removeBox.x + removeBox.width - 12, removeBox.y + removeBox.height / 2); await page.mouse.down();
      await page.mouse.move(removeBox.x + 12, removeBox.y + removeBox.height / 2, { steps: 12 }); await page.mouse.up();
      await waitUntil(() => fixture.state.context.queued_tracks.length === removeQueue.length - 1, 'Full left queue swipe must invoke Remove');
      assert.deepEqual(fixture.state.context.queued_tracks.map(track => track.id), removeQueue.slice(1), 'Full swipe must remove only its source queue entry');
      assert.equal(fixture.receivedCommands, beforeRemoveCommands + 1, 'Full swipe must issue exactly one queue change');
      assert.equal(fixture.state.track.id, initialTrack, 'Full queue swipe must not play the row');
      scenario.checks.fullQueueSwipe = 'Full left swipe removes exactly the intended queue entry without playing it';
      assert.deepEqual(scenario.errors, [], 'Unhandled browser errors');
    };
    const viewportChecks = async () => {
      assert(mobile, '--viewport-only is a focused mobile fixture');
      scenario.simulation = 'Synthetic VisualViewport, navigator.standalone, and CSS safe-area values. Real iPhone Safari chrome and HomeScreen installation still require device testing.';
      await waitUntil(async () => page.locator('html').getAttribute('data-display-mode').then(mode => mode === displayMode), 'App must identify browser versus standalone mode');
      await page.evaluate(() => {
        document.documentElement.style.setProperty('--app-safe-bottom', '34px');
        document.documentElement.style.setProperty('--app-safe-top', '59px');
      });
      const cases = scenario.viewportCases = [];
      const capture = async (name, height, top = 0, keyboard = false) => {
        await page.evaluate(values => window.__setFixtureViewport(values), { height, offsetTop: top, scale: 1 });
        await waitUntil(async () => page.locator('.app-shell').evaluate((el, height) => Math.abs(el.getBoundingClientRect().height - height) < 1, height), `${name}: shell must follow visual viewport`);
        await nextFrames();
        const metric = await page.evaluate(() => {
          const rect = selector => { const r = document.querySelector(selector).getBoundingClientRect(); return { top: r.top, bottom: r.bottom, height: r.height }; };
          const shell = document.querySelector('.app-shell'), content = document.querySelector('.content');
          return { shell: rect('.app-shell'), controls: rect('.mobile-bottom-controls'), tabs: rect('.mobile-tab-bar'), mini: rect('.mobile-mini-player'),
            reserved: parseFloat(getComputedStyle(content).paddingBottom), measuredControls: parseFloat(shell.style.getPropertyValue('--mobile-controls-height')),
            keyboard: document.documentElement.dataset.keyboardOpen === 'true', overflowX: document.documentElement.scrollWidth > innerWidth + 1 };
        });
        cases.push({ name, ...metric });
        assert(Math.abs(metric.shell.top - top) < 1, `${name}: shell must match visual viewport offset`);
        assert(Math.abs(metric.shell.bottom - (top + height)) < 1, `${name}: shell must fill the visible area`);
        assert.equal(metric.keyboard, keyboard, `${name}: keyboard classification must follow actual focused input`);
        assert(Math.abs(metric.shell.bottom - metric.tabs.bottom - (keyboard ? 12 : 34)) < 1, `${name}: bottom inset must be applied exactly once`);
        assert(Math.abs(metric.reserved - metric.controls.height - 12) <= 1, `${name}: content must reserve measured controls plus 12px (${metric.reserved} vs ${metric.controls.height} + 12)`);
        assert(Math.abs(metric.measuredControls - metric.controls.height) <= 1, `${name}: control height must be observed`);
        assert(!metric.overflowX, `${name}: no horizontal page overflow`);
      };
      await capture('full viewport with home-indicator inset', 844);
      await capture('browser chrome reduces visual viewport', 700);
      await capture('visible viewport is vertically offset', 690, 20);
      // Pinch zoom changes scale, so layout must keep the last scale=1 geometry.
      await page.evaluate(() => window.__setFixtureViewport({ height: 350, offsetTop: 80, scale: 2 }));
      await nextFrames();
      const zoom = await page.locator('.app-shell').boundingBox();
      assert(Math.abs(zoom.height - 690) < 1 && Math.abs(zoom.y - 20) < 1, 'Pinch zoom must not shrink or reposition the app layout');
      await capture('restore after zoom', 844);
      await openSongs();
      const finalRowClearance = async name => {
        await page.locator('.content').evaluate(element => { element.scrollTop = element.scrollHeight; });
        const last = page.getByRole('button', { name: 'Play Sample track 2000', exact: true });
        await last.waitFor(); await nextFrames();
        const clearance = await last.evaluate(element => document.querySelector('.mobile-bottom-controls').getBoundingClientRect().top - element.closest('.track-row').getBoundingClientRect().bottom);
        assert(clearance >= 10, `${name}: final track must clear all bottom controls by at least 10px (got ${clearance})`);
        scenario.checks[name] = clearance;
      };
      await finalRowClearance('songsFinalRow');
      await capture('songs with shorter visible area', 700);
      await finalRowClearance('shortSongsFinalRow');
      await mobileTab('Search');
      const search = page.locator('input[type="search"]:visible');
      await search.fill('Sample');
      await capture('keyboard while searching', 480, 0, true);
      await finalRowClearance('searchKeyboardFinalRow');
      await search.blur();
      await capture('keyboard dismissed but chrome remains', 700);
      await finalRowClearance('searchFinalRow');
      await capture('full viewport restored for screenshot', 844);
      await finalRowClearance('searchRestoredFinalRow');
      await shot('viewport-search-final-row');
      assert.deepEqual(scenario.errors, [], 'Unhandled browser errors');
      scenario.checks.viewport = 'Browser/standalone mode, dynamic toolbar height and offset, pinch zoom, focused keyboard, measured controls, and last-row clearance';
    };
    const downloadChecks = async () => {
      assert(mobile, '--download-only is a focused mobile fixture');
      scenario.simulation = 'Real CacheStorage and browser fetch with isolated response fixtures. HTTP bodies can be held, failed, canceled, or replaced by HTML/empty content. Offline reopen/Blob playback are covered separately by mobile-download-regression.mjs.';
      await openSongs();
      const row = () => page.locator('.track-row').filter({ hasText: 'Sample track 0002' });
      const status = () => page.locator('.app-shell > .download-status');
      const start = async () => {
        await page.locator('.content').evaluate(el => { el.scrollTop = 0; });
        await row().dispatchEvent('contextmenu');
        await page.getByRole('dialog', { name: 'Sample track 0002', exact: true }).getByRole('button', { name: 'Download', exact: true }).click();
      };
      const cached = () => page.evaluate(async () => {
        const cache = await caches.open('codec-audio-downloads-v1');
        return Promise.all((await cache.keys()).map(async request => ({ key: request.url, bytes: (await (await cache.match(request)).blob()).size })));
      });
      const dismiss = async () => { await status().getByRole('button', { name: 'Dismiss download status', exact: true }).click(); };
      const failures = scenario.downloadFailures = [];
      for (const mode of ['html', 'empty', 'unavailable']) {
        fixture.setAudioResponse(mode);
        await start();
        await waitUntil(async () => await status().getAttribute('data-state') === 'error', `${mode}: invalid download must visibly fail`);
        assert.equal(await row().getByLabel('Downloaded', { exact: true }).count(), 0, `${mode}: invalid response must not be marked downloaded`);
        assert.deepEqual(await cached(), [], `${mode}: invalid response must never enter the audio cache`);
        failures.push({ mode, message: await status().innerText() });
        await dismiss();
      }
      scenario.checks.invalidDownloads = 'HTML, empty audio and HTTP503 show persistent errors without a saved badge or cached bytes';

      fixture.setAudioResponse('valid'); fixture.holdAudioDownloads();
      let requestsBefore = fixture.audioRequests;
      await start();
      await waitUntil(() => fixture.audioRequests > requestsBefore, 'Held download must reach fixture');
      await waitUntil(async () => await status().getAttribute('data-state') === 'downloading', 'Pending download must be visible');
      assert.equal(await row().getByLabel('Downloaded', { exact: true }).count(), 0, 'Held response must not be prematurely marked downloaded');
      assert.deepEqual(await cached(), [], 'Held response must not enter audio cache before completion');
      assert.equal(await status().getByRole('progressbar', { name: 'Download progress' }).count(), 1, 'Pending download exposes progress');
      await status().getByRole('button', { name: 'Cancel downloads', exact: true }).click();
      await status().getByText('Download canceled', { exact: true }).waitFor();
      fixture.releaseAudioDownloads(); await nextFrames();
      assert.deepEqual(await cached(), [], 'Canceled download must not become cached when the server finally replies');
      await dismiss();
      scenario.checks.cancelDownload = 'Pending state, progress and cancel are visible; cancel leaves no partial or delayed cached response';

      fixture.holdAudioDownloads(); requestsBefore = fixture.audioRequests;
      await start();
      await waitUntil(() => fixture.audioRequests > requestsBefore, 'Second held download must reach fixture');
      await page.getByRole('button', { name: /^Open Now Playing:/ }).click();
      const player = page.getByRole('dialog', { name: 'Now Playing', exact: true });
      await player.locator('.download-status[data-state="downloading"]').waitFor();
      assert.equal(await player.getByRole('button', { name: 'Cancel downloads', exact: true }).isVisible(), true, 'Progress/cancel must be usable inside the top-layer sheet');
      await shot('download-pending-in-now-playing');
      fixture.releaseAudioDownloads();
      await player.locator('.download-status[data-state="done"]').waitFor();
      await page.keyboard.press('Escape'); await player.waitFor({ state: 'detached' });
      await row().getByLabel('Downloaded', { exact: true }).waitFor();
      const saved = await cached();
      assert.equal(saved.length, 1); assert.equal(saved[0].bytes, 1644, 'Saved entry must contain the full generated WAV');
      assert(saved[0].key.startsWith('https://codec-download.invalid/v1/') && !saved[0].key.includes('token'), 'Saved entry must have a credential-free stable key');
      await page.reload();
      await page.getByRole('button', { name: /^Open Now Playing:/ }).waitFor();
      scenario.downloadsAfterReload = await cached();
      assert.deepEqual(scenario.downloadsAfterReload, saved, 'Saved audio bytes must survive reload');
      await openSongs(); await row().getByLabel('Downloaded', { exact: true }).waitFor();
      assert.deepEqual(await cached(), saved, 'Saved audio and download membership must survive reload');
      scenario.checks.downloadPersistence = { bytes: saved[0].bytes, savedEntries: saved.length, topLayerProgress: true };

      await mobileTab('Library');
      if (await page.locator('.mobile-library').count() === 0) await page.locator('.mobile-toolbar').getByRole('button', { name: 'Library', exact: true }).click();
      await page.locator('.mobile-playlist-row').filter({ hasText: 'Weekend Records' }).click();
      const scansBefore = await page.evaluate(() => window.__cacheKeyScans);
      requestsBefore = fixture.audioRequests;
      fixture.holdAudioDownloads();
      await page.getByRole('button', { name: 'Download all songs', exact: true }).click();
      await waitUntil(() => fixture.audioRequests >= requestsBefore + 2, 'Collection download must start two independent transfers');
      await nextFrames();
      assert.equal(fixture.audioRequests - requestsBefore, 2, 'Collection must bound parallel transfers at two');
      assert.equal(await page.getByRole('button', { name: 'Downloading songs', exact: true }).isDisabled(), true);
      fixture.releaseAudioDownloads();
      await page.getByRole('button', { name: 'All songs downloaded', exact: true }).waitFor();
      const scansAfter = await page.evaluate(() => window.__cacheKeyScans);
      assert(scansAfter - scansBefore <= 1, 'Each completed song must not rescan all saved cache keys');
      assert.equal(fixture.audioRequests - requestsBefore, 13, 'Bulk download must fetch only the thirteen unsaved songs');
      assert.equal((await cached()).length, 14, 'Every playlist song must have real saved audio');
      assert.equal(fixture.maxActiveAudio, 2, 'At most two fixture audio transfers may overlap');
      assert(await page.locator('.track-row').count() < 100, 'Download status updates must keep row rendering bounded');
      await page.locator('.content').evaluate(el => { el.scrollTop = el.scrollHeight; });
      const last = page.getByRole('button', { name: 'Play Sample track 0014', exact: true });
      await last.waitFor(); await nextFrames();
      const clearance = await last.evaluate(el => document.querySelector('.download-status').getBoundingClientRect().top - el.closest('.track-row').getBoundingClientRect().bottom);
      assert(clearance >= 10, `Download status must not obscure the final playlist row (clearance ${clearance})`);
      scenario.checks.collectionDownloads = { fetched: fixture.audioRequests - requestsBefore, cached: 14, maxParallel: fixture.maxActiveAudio, cacheKeyScans: scansAfter - scansBefore, finalRowClearance: clearance };
      await shot('download-complete-playlist');
      assert.deepEqual(scenario.errors, [], 'Unhandled browser errors');
    };
    const songGestures = async () => {
      assert(mobile, '--song-gesture-only is a focused mobile fixture');
      scenario.simulation = 'Trusted mouse pointers exercise swipe handlers in both engines. Chromium also dispatches trusted touch; WebKit long-press events are synthetic. Physical iPhone gesture physics still require device testing.';
      await openSongs();
      const title = number => `Sample track ${String(number).padStart(4, '0')}`;
      const row = number => page.locator('.track-row').filter({ has: page.locator('.track-title-cell strong', { hasText: title(number) }) });
      const wrapper = number => page.locator('.mobile-swipe-row').filter({ has: row(number) });
      const foregroundOffset = number => row(number).evaluate(element => {
        const foreground = element.closest('.mobile-swipe-row')?.querySelector('.mobile-swipe-content') ?? element;
        return new DOMMatrixReadOnly(getComputedStyle(foreground).transform).m41;
      });
      const swipe = async (number, { direction = 1, full = false, hold = false, verticalFirst = false } = {}) => {
        await waitUntil(async () => Math.abs(await foregroundOffset(number)) < 1, 'Previous swipe action must settle before starting the next gesture');
        // Collection navigation animates its whole parent. Match Playwright's
        // ordinary click readiness before computing raw pointer coordinates.
        await row(number).click({ trial: true });
        const box = await row(number).boundingBox();
        const x = box.x + (direction > 0 ? 24 : box.width - 24), y = box.y + box.height / 2;
        await page.mouse.move(x, y); await page.mouse.down();
        if (verticalFirst) await page.mouse.move(x + 1, y + 34, { steps: 4 });
        await page.mouse.move(x + direction * (full ? box.width - 48 : 115), y + (verticalFirst ? 40 : 2), { steps: 9 });
        if (!hold) await page.mouse.up();
        return { x, y, width: box.width };
      };
      const queueIDs = () => fixture.state.context.queued_tracks.map(track => track.id);
      const expectQueue = async expected => {
        await waitUntil(() => JSON.stringify(queueIDs()) === JSON.stringify(expected), `Queue must become ${JSON.stringify(expected)}`);
        assert.equal(fixture.state.track.id, 'sample-0', 'Swipe queue actions must leave the current track unchanged');
        assert.equal(fixture.audioRequests, 0, 'Remote queue actions must not start local streaming');
        assert(fixture.commands.every(command => command.kind === 'set_queue'), 'Swipe actions must only edit the queue');
      };
      const action = (number, label) => wrapper(number).getByRole('button', { name: label === 'Remove from Playlist' ? `Remove ${title(number)} from playlist` : `${label} ${title(number)}`, exact: true });
      const clickQueueAction = async (number, label) => {
        await swipe(number);
        await action(number, label).click();
      };

      await swipe(2, { hold: true });
      await waitUntil(async () => (await foregroundOffset(2)) > 30, 'Song artwork/text must follow a right swipe before pointerup');
      await page.mouse.up();
      await action(2, 'Play Next').waitFor(); await action(2, 'Play Last').waitFor();
      assert.equal(fixture.receivedCommands, 0, 'A short swipe reveals actions without playing or queueing');
      await shot('song-swipe-next-last');
      await swipe(3);
      await action(3, 'Play Next').waitFor();
      await waitUntil(async () => Math.abs(await foregroundOffset(2)) < 1, 'Opening another song must close the first action strip');
      assert.equal(fixture.receivedCommands, 0, 'Changing the revealed row must not enqueue either song');
      await swipe(2);
      await waitUntil(async () => Math.abs(await foregroundOffset(3)) < 1, 'Only one song may expose swipe actions at a time');
      await action(2, 'Play Next').click(); await expectQueue(['sample-1']);
      await clickQueueAction(3, 'Play Last'); await expectQueue(['sample-1', 'sample-2']);
      await swipe(4, { full: true }); await expectQueue(['sample-3', 'sample-1', 'sample-2']);
      await swipe(4, { full: true }); await expectQueue(['sample-3', 'sample-3', 'sample-1', 'sample-2']);
      const queued = [...queueIDs()];
      scenario.checks.songQueueSwipe = 'Short right swipe exposes Next/Last; Next prepends, Last appends; full right swipe adds Next and repeated additions remain distinct';

      let before = fixture.receivedCommands;
      await swipe(5, { verticalFirst: true });
      await nextFrames();
      assert(Math.abs(await foregroundOffset(5)) < 1, 'Vertical-first gesture must not become a horizontal action');
      assert.equal(fixture.receivedCommands, before, 'Vertical scroll intent must not enqueue or play');
      await swipe(5, { hold: true });
      await page.evaluate(() => window.dispatchEvent(new PointerEvent('pointercancel', { pointerId: 1, pointerType: 'mouse', isPrimary: true, bubbles: true })));
      await page.mouse.up();
      await waitUntil(async () => Math.abs(await foregroundOffset(5)) < 1, 'Canceled song swipe must close');
      assert.equal(fixture.receivedCommands, before, 'Canceled swipe must not enqueue or play');
      scenario.checks.songDirectionAndCancel = 'Vertical direction lock and pointer cancellation preserve playback and queue';

      await swipe(5, { hold: true });
      await page.locator('.content').evaluate(element => { element.scrollTop = 10000; });
      await row(5).waitFor({ state: 'detached' });
      await page.mouse.up(); await nextFrames();
      assert.equal(fixture.receivedCommands, before, 'A gesture whose source row unmounts must not enqueue a recycled row');
      const deep = await page.locator('.track-row').evaluateAll(elements => {
        const top = document.querySelector('.content').getBoundingClientRect().top;
        const bottom = document.querySelector('.mobile-mini-player').getBoundingClientRect().top;
        const element = elements.find(element => { const box = element.getBoundingClientRect(); return box.top >= top && box.bottom < bottom; });
        return element ? { id: element.dataset.trackId, index: Number(element.dataset.trackIndex), name: element.querySelector('strong').textContent } : null;
      });
      assert(deep && deep.index > 50, 'Deep-scroll fixture must target a globally indexed track');
      const number = Number(deep.name.match(/\d+$/)[0]);
      assert.equal(deep.id, `sample-${number - 1}`, 'Virtual row identity must match its title');
      await swipe(number, { full: true }); await expectQueue([deep.id, ...queued]);
      assert(await page.locator('.track-row').count() < 100, 'Swiping must preserve bounded row rendering');
      scenario.checks.songVirtualIdentity = { trackID: deep.id, globalIndex: deep.index, title: deep.name, mountedRows: await page.locator('.track-row').count() };

      await page.locator('.content').evaluate(element => { element.scrollTop = 0; });
      await row(2).waitFor();
      if (browserName === 'chromium') {
        const touch = await context.newCDPSession(page), box = await row(2).boundingBox();
        const x = box.x + 24, y = box.y + box.height / 2;
        const order = [...queueIDs()], commandsBeforeTouch = fixture.receivedCommands;
        await touch.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y, id: 0 }] });
        await touch.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x + 65, y: y + 1, id: 0 }] });
        await waitUntil(async () => (await foregroundOffset(2)) > 30, 'Trusted touch must continue following the finger after implicit capture transfer');
        await touch.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x + 115, y: y + 1, id: 0 }] });
        await touch.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
        assert.equal(fixture.receivedCommands, commandsBeforeTouch, 'Trusted short swipe must not auto-play or auto-enqueue');
        await action(2, 'Play Next').click(); await expectQueue(['sample-1', ...order]);
        await touch.detach();
        scenario.checks.songTrustedTouch = 'Trusted touch reveals queue actions through implicit pointer capture; the action queues exactly once without playing';
      }
      await swipe(2, { direction: -1 });
      await action(2, 'Like').click();
      await waitUntil(() => fixture.tracks[1].is_liked, 'Left-swipe Like must persist the intended track');
      await swipe(2, { direction: -1 });
      await action(2, 'Unlike').waitFor();
      await action(2, 'Download').click();
      await row(2).getByLabel('Downloaded', { exact: true }).waitFor();
      const saved = await page.evaluate(async () => (await (await caches.open('codec-audio-downloads-v1')).keys()).map(request => request.url));
      assert.equal(saved.length, 1, 'Left-swipe Download must save real audio');
      assert(saved[0].endsWith('/sample-1'), 'Download must use the swiped track identity');
      assert.equal(fixture.state.track.id, 'sample-0', 'Like/download must not start playback');
      await page.locator('.app-shell > .download-status').getByRole('button', { name: 'Dismiss download status', exact: true }).click();
      scenario.checks.songTrailingActions = 'Left swipe persists Like/Unlike state and saves the intended audio without playing it';

      // A normal tap and long press must still work after gesture cancellation.
      const longPressTarget = row(6).locator('.track-title-cell strong');
      before = fixture.receivedCommands;
      if (browserName === 'chromium') {
        const touch = await context.newCDPSession(page), box = await longPressTarget.boundingBox();
        await touch.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: box.x + 10, y: box.y + box.height / 2, id: 0 }] });
        await page.getByRole('dialog', { name: title(6), exact: true }).waitFor();
        await touch.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
        await touch.detach();
      } else {
        const box = await longPressTarget.boundingBox();
        await longPressTarget.dispatchEvent('pointerdown', { pointerId: 31, pointerType: 'touch', isPrimary: true, button: 0, clientX: box.x + 10, clientY: box.y + box.height / 2 });
        await page.getByRole('dialog', { name: title(6), exact: true }).waitFor();
        await page.evaluate(() => window.dispatchEvent(new PointerEvent('pointerup', { pointerId: 31, pointerType: 'touch', isPrimary: true, bubbles: true })));
      }
      const menu = page.getByRole('dialog', { name: title(6), exact: true });
      await menu.getByRole('button', { name: 'Play Next', exact: true }).waitFor();
      await menu.getByRole('button', { name: 'Play Last', exact: true }).waitFor();
      assert.equal(fixture.receivedCommands, before, 'Long press must open the menu without playing or queueing');
      await page.keyboard.press('Escape'); await menu.waitFor({ state: 'detached' });
      await page.waitForTimeout(750); // Deliberate long-press click-suppression window.
      await page.locator('.content').evaluate(element => { element.scrollTop = 180; });
      await row(7).click();
      await waitUntil(() => fixture.state.track.id === 'sample-6', 'Normal row tap must still play the selected song');
      scenario.checks.songTapAndLongPress = { normalTap: 'plays intended song', longPress: browserName === 'chromium' ? 'trusted touch opens menu without play' : 'synthetic touch opens menu without play' };

      // A playlist supplies a remove action instead of changing library likes.
      await mobileTab('Library');
      if (await page.locator('.mobile-library').count() === 0) await page.locator('.mobile-toolbar').getByRole('button', { name: 'Library', exact: true }).click();
      await page.locator('.mobile-playlist-row').filter({ hasText: 'Weekend Records' }).click();
      await swipe(2, { direction: -1 });
      await action(2, 'Remove from Playlist').click();
      await waitUntil(() => !fixture.library.playlists[0].track_ids.includes('sample-1'), 'Playlist swipe remove must persist the intended song removal');
      assert.equal(fixture.state.track.id, 'sample-6', 'Playlist remove must not change playback');
      scenario.checks.songPlaylistRemove = 'Playlist trailing action removes only the intended membership';

      await row(3).click({ button: 'right' });
      await page.getByRole('dialog', { name: title(3), exact: true }).getByRole('button', { name: 'Add to Playlist', exact: true }).click();
      const memberships = page.getByRole('dialog', { name: 'Add to Playlist', exact: true });
      const weekendChoice = memberships.getByRole('checkbox', { name: 'Weekend Records', exact: true });
      assert.equal(await weekendChoice.isChecked(), true, 'Membership fixture must start with this song in the playlist');
      await memberships.locator('label').filter({ hasText: 'Weekend Records' }).click();
      assert.equal(await weekendChoice.isChecked(), false);
      await page.keyboard.press('Escape'); await memberships.waitFor({ state: 'detached' });
      await waitUntil(() => !fixture.library.playlists[0].track_ids.includes('sample-2'), 'Escape must save the staged mobile playlist membership');
      assert.equal(fixture.state.track.id, 'sample-6', 'Membership dismissal must not change playback');
      scenario.checks.membershipEscape = 'Escape commits the staged mobile playlist selection just like Done/dismissal';

      await mobileTab('Library');
      if (await page.locator('.mobile-library').count() === 0) await page.locator('.mobile-toolbar').getByRole('button', { name: 'Library', exact: true }).click();
      const playlistRow = page.locator('.mobile-playlist-row[data-playlist-id="fixture-collage"]');
      const playlistWrapper = page.locator('.mobile-swipe-row[data-swipe-id="fixture-collage"]');
      const allTrackIDs = fixture.library.tracks.map(track => track.id), beforeDeleteQueue = [...queueIDs()];
      const deleteCount = () => fixture.mutations.filter(item => item.method === 'DELETE' && item.playlist === 'fixture-collage').length;
      const revealDelete = async () => {
        await waitUntil(async () => playlistWrapper.locator('.mobile-swipe-content').evaluate(element => Math.abs(new DOMMatrixReadOnly(getComputedStyle(element).transform).m41) < 1), 'Playlist action must settle before next swipe');
        await playlistRow.click({ trial: true });
        const box = await playlistRow.boundingBox(), y = box.y + box.height / 2;
        await page.mouse.move(box.x + box.width - 20, y); await page.mouse.down();
        await page.mouse.move(box.x + 20, y, { steps: 12 }); await page.mouse.up();
        await playlistWrapper.getByRole('button', { name: 'Delete playlist Late Night Mix', exact: true }).waitFor();
      };
      await revealDelete();
      assert.equal(deleteCount(), 0, 'Even a full playlist swipe must not delete without confirmation');
      assert.equal(await page.getByRole('dialog', { name: 'Delete Playlist?', exact: true }).count(), 0, 'Full playlist swipe only reveals Delete');
      const confirm = () => page.getByRole('dialog', { name: 'Delete Playlist?', exact: true });
      await playlistWrapper.getByRole('button', { name: 'Delete playlist Late Night Mix', exact: true }).click();
      await confirm().getByRole('button', { name: 'Cancel', exact: true }).click();
      await confirm().waitFor({ state: 'detached' });
      assert.equal(deleteCount(), 0, 'Cancel must send no delete request');
      assert(fixture.library.playlists.some(playlist => playlist.id === 'fixture-collage'));
      await revealDelete();
      await playlistWrapper.getByRole('button', { name: 'Delete playlist Late Night Mix', exact: true }).click();
      fixture.setPlaylistDeleteFailure(true);
      await confirm().getByRole('button', { name: 'Delete', exact: true }).click();
      await confirm().getByRole('alert').waitFor();
      assert.equal(deleteCount(), 1, 'Confirmed failure must attempt one delete');
      assert(fixture.library.playlists.some(playlist => playlist.id === 'fixture-collage'), 'Server failure must preserve the playlist');
      assert.equal(await playlistRow.count(), 1, 'Failed playlist delete must keep the row');
      await shot('playlist-delete-retry');
      fixture.setPlaylistDeleteFailure(false);
      await confirm().getByRole('button', { name: 'Delete', exact: true }).click();
      await confirm().waitFor({ state: 'detached' });
      await playlistRow.waitFor({ state: 'detached' });
      assert.equal(deleteCount(), 2, 'Explicit retry must send one new delete request');
      assert.deepEqual(fixture.library.tracks.map(track => track.id), allTrackIDs, 'Deleting a playlist must retain every library track');
      assert.deepEqual(queueIDs(), beforeDeleteQueue, 'Deleting a playlist must retain the current queue');
      assert.equal(fixture.state.track.id, 'sample-6', 'Deleting a playlist must retain current playback');
      scenario.checks.playlistDelete = 'Full swipe only reveals; cancel sends nothing; failed confirmation preserves playlist; successful retry removes only playlist, retaining all 2000 tracks and queue';

      const beforeGuestMutations = fixture.mutations.length;
      await page.goto(`${baseURL}/?aux=ABCD`);
      await page.getByRole('button', { name: /^Open Now Playing:/ }).waitFor();
      await openSongs();
      assert.equal(await page.evaluate(async () => (await (await caches.open('codec-audio-downloads-v1')).keys()).length), 1, 'Guest fixture retains the owner download while testing restricted actions');
      before = fixture.receivedCommands;
      const guestOrder = [...queueIDs()];
      await swipe(2); await action(2, 'Play Last').click();
      await waitUntil(() => JSON.stringify(queueIDs()) === JSON.stringify([...guestOrder, 'sample-1']), 'Guest swipe queue action must work');
      assert.equal(fixture.receivedCommands, before + 1, 'Guest queue action must issue one command');
      assert.equal(fixture.state.track.id, 'sample-6', 'Guest queue swipe must retain the current song');
      before = fixture.receivedCommands;
      await swipe(3, { direction: -1 });
      await nextFrames();
      assert.equal(await wrapper(3).getByRole('button', { name: /^(?:Like|Unlike|Download|Remove) / }).count(), 0, 'Guest rows must not expose owner swipe actions');
      assert.equal(fixture.receivedCommands, before, 'Guest unavailable left swipe must not accidentally play');
      await row(3).click({ button: 'right' });
      const guestMenu = page.getByRole('dialog', { name: title(3), exact: true });
      await guestMenu.getByRole('button', { name: 'Play Next', exact: true }).waitFor();
      for (const label of ['Like', 'Unlike', 'Download', 'Remove Download', 'Add to Playlist', 'Remove from Playlist']) {
        assert.equal(await guestMenu.getByRole('button', { name: label, exact: true }).count(), 0, `Guest menu must hide ${label}`);
      }
      assert.equal(fixture.mutations.length, beforeGuestMutations, 'Guest gestures must not mutate likes or playlists');
      await shot('song-guest-menu');
      scenario.checks.songGuestActions = 'Guests can queue by swipe, while owner swipe/menu actions stay absent';
      assert.deepEqual(scenario.errors, [], 'Unhandled browser errors');
    };

    const desktopPlayerChecks = async () => {
      assert(!mobile, '--desktop-player-only requires a desktop viewport above 980px');
      // A footer inside the app's section has no implicit contentinfo role.
      const footer = page.locator('footer.player[aria-label="Player"]');
      const track = fixture.tracks.find(track => track.id === fixture.state.track?.id);
      assert(track, 'Desktop footer fixture requires a current track');
      const title = track.title, originalTrackID = track.id, revision = fixture.state.revision;
      const like = liked => footer.getByRole('button', { name: `${liked ? 'Unlike' : 'Like'} ${title}`, exact: true });
      const add = () => footer.getByRole('button', { name: `Add ${title} to playlist`, exact: true });
      const ownerActions = () => footer.getByRole('button', { name: /^(?:Like |Unlike |Add .+ to playlist$)/ });
      const refresh = async () => {
        const before = fixture.libraryReads;
        await page.evaluate(() => window.dispatchEvent(new Event('pageshow')));
        await waitUntil(() => fixture.libraryReads > before, 'Foreground refresh must read the remote library');
      };
      const beforeMutations = fixture.mutations.length, beforeCommands = fixture.receivedCommands, beforeAudioRequests = fixture.audioRequests;
      await like(false).waitFor(); await add().waitFor();
      for (const desired of [true, false]) {
        const before = fixture.mutations.length;
        await like(!desired).click();
        await waitUntil(() => fixture.mutations.length > before && track.is_liked === desired, 'Footer Like must persist the selected state on the current song');
        await like(desired).waitFor();
        const mutation = fixture.mutations.at(-1);
        assert.equal(mutation.track, originalTrackID); assert.equal(mutation.liked, desired);
        assert.equal(mutation.authenticated, true, 'Footer Like must use the existing authenticated mutation handler');
      }
      assert.equal(fixture.mutations.length - beforeMutations, 2, 'Like on/off sends exactly two mutations');
      scenario.checks.desktopFooterLike = 'Like/Unlike persists on the current song through authenticated requests';

      // Keep the playback reference/revision unchanged, so only a library
      // update can replace stale metadata in the mounted footer.
      for (const desired of [true, false]) {
        track.is_liked = desired;
        fixture.library.stats.likedCount = fixture.tracks.filter(track => track.is_liked).length;
        fixture.library.scanned_at++;
        await refresh(); await like(desired).waitFor();
        assert.equal(fixture.state.track.id, originalTrackID); assert.equal(fixture.state.revision, revision);
      }
      assert.equal(fixture.mutations.length - beforeMutations, 2, 'A remote library update must not echo a like mutation');
      scenario.checks.desktopFooterLibraryRefresh = 'Same-track library refresh updates Like state without a playback change or echoed mutation';

      await like(false).click();
      await waitUntil(() => track.is_liked, 'Membership fixture must begin with a liked current song');
      await like(true).waitFor();
      const playlist = fixture.library.playlists.find(playlist => !playlist.is_liked);
      const originalMember = playlist.track_ids.includes(originalTrackID);
      const unaffected = fixture.library.playlists.filter(item => item.id !== playlist.id).map(item => [item.id, [...item.track_ids]]);
      const playlistMutationStart = fixture.mutations.length;
      for (const desired of [!originalMember, originalMember]) {
        await add().click();
        const modal = page.getByRole('dialog', { name: `Edit playlists for ${title}`, exact: true });
        await modal.waitFor();
        const choice = modal.getByRole('checkbox', { name: new RegExp(playlist.name) });
        assert.equal(await choice.isChecked(), !desired, 'Footer playlist editor must reflect the latest saved membership');
        // The existing editor styles a custom checkbox over its input; use
        // the associated visible label, just as a pointer user does.
        await modal.locator('label.playlist-choice').filter({ hasText: playlist.name }).click();
        assert.equal(await choice.isChecked(), desired);
        await modal.getByRole('button', { name: 'Save', exact: true }).click();
        await modal.waitFor({ state: 'detached' });
        await waitUntil(() => playlist.track_ids.includes(originalTrackID) === desired, 'Footer playlist Save must persist the current song membership');
        assert.equal(fixture.mutations.at(-1).authenticated, true, 'Playlist Save must use the existing authenticated mutation handler');
        assert.equal(track.is_liked, true, 'Editing ordinary playlists must not persist an unlike');
        await like(true).waitFor();
        await refresh();
        await like(true).waitFor();
      }
      assert.equal(fixture.mutations.length - playlistMutationStart, 2, 'Playlist membership round trip sends one mutation per Save');
      assert.deepEqual(fixture.library.playlists.filter(item => item.id !== playlist.id).map(item => [item.id, [...item.track_ids]]), unaffected);
      await add().click();
      const savedModal = page.getByRole('dialog', { name: `Edit playlists for ${title}`, exact: true });
      assert.equal(await savedModal.getByRole('checkbox', { name: new RegExp(playlist.name) }).isChecked(), originalMember);
      await savedModal.getByRole('button', { name: 'Cancel', exact: true }).click();
      await savedModal.waitFor({ state: 'detached' });
      await like(true).click();
      await waitUntil(() => !track.is_liked, 'Restore original Like state after playlist checks');
      await like(false).waitFor();
      assert.equal(fixture.state.track.id, originalTrackID); assert.equal(fixture.receivedCommands, beforeCommands);
      assert.equal(fixture.audioRequests, beforeAudioRequests, 'Footer library actions must not start or reload local playback');
      for (const button of [like(false), add()]) {
        const bounds = await button.boundingBox();
        assert(bounds && bounds.width > 0 && bounds.height > 0 && bounds.x >= 0 && bounds.x + bounds.width <= width, 'Footer actions must remain visible inside the desktop viewport');
      }
      await shot('desktop-footer-actions');
      scenario.checks.desktopFooterPlaylists = 'Current-song PlaylistModal saves/removes membership, reopens with persisted selection, and preserves likes, other playlists and playback without a transport command';

      const restorePlayback = fixture.clearPlayback();
      await refresh(); await footer.getByText('Nothing playing', { exact: true }).waitFor();
      assert.equal(await ownerActions().count(), 0, 'An empty player must expose no track mutation buttons');
      await shot('desktop-footer-empty');
      restorePlayback(); await refresh(); await footer.getByText(title, { exact: true }).waitFor();
      scenario.checks.desktopFooterEmpty = 'No Like or playlist button when there is no current song';

      const beforeGuestMutations = fixture.mutations.length;
      const joined = page.waitForResponse(response => new URL(response.url()).pathname === '/api/v1/aux/join');
      await page.goto(`${baseURL}/?aux=ABCD`); await joined;
      await footer.getByText(title, { exact: true }).waitFor();
      assert.equal(await ownerActions().count(), 0, 'Aux guests must not receive owner-only footer mutation buttons');
      assert.equal(fixture.mutations.length, beforeGuestMutations);
      await shot('desktop-footer-guest');
      scenario.checks.desktopFooterGuest = 'Aux guest footer hides Like and playlist actions without mutating the library';
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), false, 'Desktop footer actions must not cause horizontal page overflow');
      assert.deepEqual(scenario.errors, [], 'Unhandled browser errors');
    };

    try {
      await page.goto(baseURL);
      await page.locator('.app-shell').waitFor();
      await waitUntil(async () => mobile ? await page.getByRole('button', { name: /^Open Now Playing:/ }).count() > 0 : await page.locator('.player .now-playing').getByText('Sample track 0001', { exact: true }).count() > 0, 'Initial playback state did not load');
      if (!mobile) {
        const rows = await page.locator('.queue-rail-row').count();
        assert(width <= 1140 ? rows === 0 : rows > 0 && rows < 80, 'Desktop queue must mount only visible rows, and no rail at its hidden breakpoint');
        scenario.checks.initialDesktopQueueRows = rows;
      }
      await shot('home');
      if (profileOnly) { await profile(); continue; }
      if (interactionOnly) { await interactions(); continue; }
      if (viewportOnly) { await viewportChecks(); continue; }
      if (downloadOnly) { await downloadChecks(); continue; }
      if (songGestureOnly) { await songGestures(); continue; }
      if (desktopPlayerOnly) { await desktopPlayerChecks(); continue; }

      if (mobile) {
        for (const name of ['Search', 'Library', 'Visualizer', 'Home']) {
          await mobileTab(name);
          await waitUntil(async () => await page.locator('.app-shell').getAttribute('data-view') === name.toLowerCase(), `${name} navigation failed`);
          await shot(name.toLowerCase());
        }
        await mobileTab('Library');
        const custom = page.locator('.mobile-playlist-row').filter({ hasText: 'Weekend Records' }).locator('img');
        await waitUntil(() => custom.evaluate((image) => image.complete && image.naturalWidth > 0), 'Custom playlist artwork did not load');
        assert.equal(await page.locator('.mobile-playlist-row').filter({ hasText: 'Late Night Mix' }).locator('img').count(), 4, 'Playlist collage must show four images');
        scenario.checks.playlistArtwork = 'custom cover and four-tile fallback';
        assert.equal(await page.locator('.mobile-library').getByRole('button', {name:/^Albums|^Artists/}).count(),0);
        assert.equal(await page.locator('.mobile-music-group > button').count(),3,'Native Library has Liked Songs, Songs, Downloaded');
        assert.equal(await page.locator('.mobile-library-title').isVisible(),false,'Only the toolbar should show the Library title');
        await page.locator('.mobile-library-group').getByRole('button', { name: /^Liked Songs/ }).click();
      } else await page.getByRole('button', { name: 'Liked Songs', exact: true }).click();
      if(mobile) await page.locator('.empty-state .native-empty-label').first().waitFor();
      else await page.getByText('No tracks here.', {exact:true}).waitFor();
      await openSongs();
      await deepScroll('empty-liked-to-songs');
      await page.locator('.content').evaluate(el=>{el.scrollTop=el.scrollHeight});
      await page.locator('.track-surface').getByRole('button',{name:'Play Sample track 2000',exact:true}).waitFor();
      const endClearance = await page.locator('.track-surface').getByRole('button',{name:'Play Sample track 2000',exact:true}).evaluate(el=>{
        const bottom=document.querySelector('.mobile-mini-player')?.getBoundingClientRect().top ?? document.querySelector('.content').getBoundingClientRect().bottom;
        return bottom-el.getBoundingClientRect().bottom;
      });
      if(endClearance < -1) scenario.issues.push(`Last track is obscured by ${-endClearance}px`);
      scenario.checks.endScrollClearance=endClearance;
      if(mobile){
        await page.locator('select[aria-label="Sort songs"]').selectOption('added');
        await page.locator('.content').evaluate(el=>{el.scrollTop=0});
        await waitUntil(async()=> (await listMetrics(page)).first?.includes('Sample track 2000'),'Newest sort must put newest track first');
        await page.locator('select[aria-label="Sort songs"]').selectOption('default');
        scenario.checks.nativeSort='Default and Newest work';
      }

      if (mobile) await mobileTab('Search');
      else await page.getByRole('button', { name: 'Home', exact: true }).click();
      const search = page.locator('input[type="search"]:visible');
      await search.fill('no-fixture-track-has-this-name');
      await waitUntil(async () => await page.locator('.track-row').count() === 0, 'Unmatched search must be empty');
      await search.fill('Sample');
      await page.locator('.track-row').first().waitFor();
      await deepScroll('empty-search-to-results');

      await openSongs();
      await page.locator('.content').evaluate((element) => { element.scrollTop = 0; });
      await page.locator('.track-surface').getByRole('button', { name: 'Play Sample track 0002', exact: true }).waitFor();
      fixture.holdNextCommand();
      const add = async (number) => {
        const title = `Sample track ${String(number).padStart(4, '0')}`;
        if (mobile) {
          await page.locator('.track-row').filter({ hasText: title }).dispatchEvent('contextmenu');
          await page.getByRole('dialog', { name: title, exact: true }).getByRole('button', { name: 'Play Last', exact: true }).click();
        } else await page.getByRole('button', { name: `Add ${title} to queue`, exact: true }).click();
      };
      await add(2);
      await waitUntil(() => fixture.receivedCommands === 1, 'First queue command did not reach the fixture');
      await add(3);
      fixture.releaseCommand();
      await waitUntil(() => fixture.commands.length === 2, 'Second queued command did not complete');
      assert.deepEqual(fixture.commands.map((command) => command.expected), ['"1"', '"2"']);
      assert.deepEqual(fixture.commands.map((command) => command.status), [200, 200]);
      assert.deepEqual(fixture.state.context.queued_tracks.map((track) => track.id), ['sample-1', 'sample-2']);
      scenario.checks.rapidQueueCommands = fixture.commands.slice();

      if (mobile) {
        await page.getByRole('button', { name: /^Open Now Playing:/ }).click();
        await page.getByRole('dialog', { name: 'Now Playing', exact: true }).waitFor();
        await shot('now-playing');
        await page.getByRole('dialog', { name: 'Now Playing', exact: true }).getByRole('button', { name: 'Queue', exact: true }).click();
        await page.getByRole('dialog', { name: 'Queue', exact: true }).waitFor();
        await shot('queue');
        await page.getByRole('dialog', { name: 'Queue', exact: true }).getByRole('button', { name: 'Edit', exact: true }).click();
        await page.getByRole('dialog', { name: 'Queue', exact: true }).getByRole('button', { name: /^Reorder Sample track 0003/ }).first().focus();
        await page.keyboard.press('ArrowUp');
        await waitUntil(() => fixture.state.context.queued_tracks[0]?.id === 'sample-2', 'Queue move used the wrong global index');
        const handles=page.locator('.native-queue-sheet [data-queue-group="manual"] .queue-reorder-control');
        const dragFrom=await handles.nth(0).boundingBox(),dragTo=await handles.nth(1).boundingBox();
        await page.mouse.move(dragFrom.x+dragFrom.width/2,dragFrom.y+dragFrom.height/2);
        await page.mouse.down();
        await page.mouse.move(dragTo.x+dragTo.width/2,dragTo.y+dragTo.height/2,{steps:8});
        await page.mouse.up();
        await waitUntil(()=>fixture.state.context.queued_tracks[0]?.id==='sample-1','Pointer queue reorder failed');
        await page.getByRole('button', { name: 'Remove Sample track 0002 from queue', exact: true }).first().click();
        await waitUntil(() => fixture.state.context.queued_tracks.length === 1, 'Queue removal did not complete');
        assert.deepEqual(fixture.state.context.queued_tracks.map((track) => track.id), ['sample-2']);
        scenario.checks.queueEditing = 'pointer/keyboard reorder and remove preserve global queue indices';
        await deepScroll('queue-up-next-scroll', '.native-queue-sheet .mobile-queue-row', '.native-queue-sheet .mobile-sheet-body');
        await page.keyboard.press('Escape');
        await page.getByRole('dialog', { name: 'Queue', exact: true }).waitFor({ state: 'detached' });
        await page.keyboard.press('Escape');
        if (width === 390) {
          fixture.seedLargeManualQueue();
          await page.reload();
          await page.getByRole('button', { name: /^Open Now Playing:/ }).click();
          await page.getByRole('dialog', { name: 'Now Playing', exact: true }).getByRole('button', { name: 'Queue', exact: true }).click();
          await deepScroll('large-manual-queue-scroll', '.native-queue-sheet .mobile-queue-row', '.native-queue-sheet .mobile-sheet-body');
          await page.keyboard.press('Escape');
        await page.getByRole('dialog', { name: 'Queue', exact: true }).waitFor({ state: 'detached' });
        await page.keyboard.press('Escape');
        }
      }
      if(mobile) {
        const libraryRoot=async()=>{
          await mobileTab('Library');
          if(await page.locator('.mobile-library').count()===0)await page.locator('.mobile-toolbar').getByRole('button',{name:'Library',exact:true}).click();
        };
        await libraryRoot();
        await page.locator('.mobile-playlist-row').filter({hasText:'Weekend Records'}).click();
        await page.locator('.native-collection-toolbar').getByRole('button',{name:'Edit',exact:true}).click();
        const second=page.getByRole('button',{name:'Reorder Sample track 0002',exact:true});
        await second.focus();await page.keyboard.press('ArrowDown');
        await waitUntil(()=>fixture.library.playlists[0].track_ids[2]==='sample-1','Playlist keyboard reorder did not persist');
        await page.keyboard.press('ArrowDown');
        await waitUntil(()=>fixture.library.playlists[0].track_ids[3]==='sample-1','Playlist reorder lost keyboard focus');
        const from=await page.getByRole('button',{name:'Reorder Sample track 0001',exact:true}).boundingBox();
        const to=await page.getByRole('button',{name:'Reorder Sample track 0003',exact:true}).boundingBox();
        await page.mouse.move(from.x+from.width/2,from.y+from.height/2);await page.mouse.down();
        await page.mouse.move(to.x+to.width/2,to.y+to.height/2,{steps:8});await page.mouse.up();
        await waitUntil(()=>fixture.library.playlists[0].track_ids[0]==='sample-2','Playlist pointer reorder failed');
        await page.getByRole('button',{name:'Remove Sample track 0004 from playlist',exact:true}).click();
        await waitUntil(()=>!fixture.library.playlists[0].track_ids.includes('sample-3'),'Playlist removal failed');
        await mobileTab('Search');
        assert.equal(await page.locator('.native-playlist-reorder:visible').count(),0,'Playlist editing must not leak into another tab');
        await libraryRoot();await page.locator('.mobile-playlist-row').filter({hasText:'Weekend Records'}).click();
        await page.getByRole('button',{name:'Add songs',exact:true}).click();
        const addSheet=page.getByRole('dialog',{name:'Add Songs',exact:true});
        await addSheet.waitFor();
        assert(await addSheet.locator('.native-song-choice').count()<100,'Add Songs must virtualize the full library');
        await page.getByRole('searchbox',{name:'Search songs to add',exact:true}).fill('Sample track 0021');
        await addSheet.getByRole('button').filter({hasText:'Sample track 0021'}).click();
        await waitUntil(()=>fixture.library.playlists[0].track_ids.includes('sample-20'),'Add Songs did not persist');
        await page.keyboard.press('Escape');
        scenario.checks.playlistEditing='pointer/keyboard reorder, repeated keyboard focus, remove and add songs';
        await openSongs();
        await page.locator('.content').evaluate(el=>{el.scrollTop=0});
        const downloadedRow=()=>page.locator('.track-row').filter({hasText:'Sample track 0002'});
        await downloadedRow().dispatchEvent('contextmenu');
        await page.getByRole('dialog',{name:'Sample track 0002',exact:true}).getByRole('button',{name:'Download',exact:true}).click();
        await downloadedRow().getByLabel('Downloaded',{exact:true}).waitFor();
        const cached=await page.evaluate(async()=>{const store=await caches.open('codec-audio-downloads-v1');return(await store.keys()).map(key=>key.url)});
        assert.equal(cached.length,1);assert(!cached[0].includes('token'),'Cache must not retain stream credentials');
        assert.equal(fixture.audioRequests,1,'Download should fetch one audio file');
        await libraryRoot();
        const downloadedButton=page.locator('.mobile-music-group').getByRole('button',{name:/^Downloaded/});
        assert((await downloadedButton.textContent()).includes('1'),'Downloaded count did not refresh');
        await downloadedButton.click();
        assert.equal(await page.locator('.track-row').count(),1,'Downloaded collection must show cached songs only');
        assert.equal(await page.getByRole('button',{name:'All songs downloaded',exact:true}).count(),0,'Native Downloaded collection has no download-all control');
        await shot('downloaded');
        await downloadedRow().dispatchEvent('contextmenu');
        await page.getByRole('dialog',{name:'Sample track 0002',exact:true}).getByRole('button',{name:'Remove Download',exact:true}).click();
        await waitUntil(async()=>await page.locator('.track-row').count()===0,'Removed download remains in Downloaded');
        scenario.checks.downloads='real CacheStorage download, count, collection and removal';
        if(width===390){
          const beforeMutations=fixture.mutations.length;
          await page.goto(`${baseURL}/?aux=ABCD`);
          await page.getByRole('button',{name:/^Open Now Playing:/}).waitFor();
          await mobileTab('Home');
          await page.getByRole('button',{name:'Aux session',exact:true}).waitFor();
          await libraryRoot();
          assert.equal(await page.getByRole('button',{name:'New playlist',exact:true}).count(),0,'Guest must not create playlists');
          await page.locator('.mobile-playlist-row').filter({hasText:'Weekend Records'}).click();
          assert.equal(await page.locator('.native-collection-toolbar button').count(),0,'Guest must not edit playlist, cover or membership');
          await page.locator('.track-row').first().dispatchEvent('contextmenu');
          const actions=page.getByRole('dialog').last();
          for(const label of ['Like','Unlike','Download','Add to Playlist'])assert.equal(await actions.getByRole('button',{name:label,exact:true}).count(),0,`Guest action ${label} must be hidden`);
          assert.equal(await actions.getByRole('button',{name:'Play Next',exact:true}).count(),1);
          assert.equal(fixture.mutations.length,beforeMutations,'Guest navigation must not mutate playlists');
          await page.keyboard.press('Escape');
          scenario.checks.guest='Guest library and row controls omit owner mutations';
        }
      }
      if (!mobile) {
        if (width <= 1140) {
          await page.setViewportSize({ width: 1440, height: 960 });
          await page.locator('.queue-now').waitFor();
        }
        const rail = page.locator('.queue-rail');
        const manual = rail.locator('[aria-label="In Queue"]');
        const refresh = () => page.evaluate(() => window.dispatchEvent(new Event('pageshow')));
        await page.evaluate(() => {
          window.queueRowChanges = { added: 0, removed: 0 };
          window.queueRowObserver = new MutationObserver(records => {
            for (const record of records) for (const kind of ['added', 'removed']) {
              for (const node of record[`${kind}Nodes`]) if (node instanceof Element) {
                window.queueRowChanges[kind] += Number(node.matches('.queue-rail-row')) + node.querySelectorAll('.queue-rail-row').length;
              }
            }
          });
          window.queueRowObserver.observe(document.querySelector('.queue-rail'), { childList: true, subtree: true });
        });
        const artworkBefore = fixture.artworkRequests;
        fixture.advanceSource();
        await refresh();
        await rail.locator('.queue-now').getByText('Sample track 0002', { exact: true }).waitFor();
        const changes = await page.evaluate(() => { window.queueRowObserver.disconnect(); return window.queueRowChanges; });
        assert(changes.added < 10 && changes.removed < 10, `Next-track update remounted the queue: ${JSON.stringify(changes)}`);
        assert.equal(fixture.artworkRequests, artworkBefore, 'Unchanged warm queue covers must not be downloaded again');
        scenario.checks.desktopNextTrackRowChanges = changes;
        scenario.checks.desktopNextTrackArtworkRequests = fixture.artworkRequests - artworkBefore;

        fixture.seedDesktopQueue();
        await refresh();
        await waitUntil(async () => await manual.locator('.queue-rail-row').count() > 3, 'Large manual queue did not arrive');
        assert(await rail.locator('.queue-rail-row').count() < 80, 'Large manual queue must remain virtualized');
        assert.equal(await manual.getByText('Sample track 0002', { exact: true }).count(), 2, 'Repeated manual entries must remain distinct');
        const beforeMove = fixture.state.context.queued_tracks.map(track => track.id);
        await manual.locator('.queue-rail-row').nth(0).dragTo(manual.locator('.queue-rail-row').nth(3));
        const expectedMove = [...beforeMove]; expectedMove.splice(3, 0, ...expectedMove.splice(0, 1));
        await waitUntil(() => fixture.state.context.queued_tracks[3]?.id === beforeMove[0], 'Desktop pointer reorder did not preserve the selected duplicate');
        assert.deepEqual(fixture.state.context.queued_tracks.map(track => track.id), expectedMove);

        await manual.locator('.queue-rail-row').first().focus();
        for (let index = 0; index < 200; index += 1) await page.keyboard.press('Tab');
        const tabbedIndex = await page.evaluate(() => Number(document.activeElement?.closest('.virtual-row')?.getAttribute('data-virtual-index')));
        assert.equal(tabbedIndex, 100, 'Tab navigation must cross virtual windows without losing its queue position');
        assert(await rail.locator('.queue-rail-row').count() < 80, 'Keyboard traversal must keep queue rendering bounded');
        scenario.checks.desktopQueueTabTraversal = { presses: 200, rowIndex: tabbedIndex };
        for (let index = 0; index < 20; index += 1) await page.keyboard.press('Shift+Tab');
        assert.equal(await page.evaluate(() => Number(document.activeElement?.closest('.virtual-row')?.getAttribute('data-virtual-index'))), 90,
          'Reverse Tab navigation must cross virtual windows too');
        await manual.evaluate(section => {
          const scroller = section.closest('.queue-rail-list');
          scroller.scrollTop += section.getBoundingClientRect().bottom - scroller.getBoundingClientRect().bottom;
        });
        const lastManualIndex = fixture.state.context.queued_tracks.length - 1;
        const lastRemove = manual.locator(`[data-virtual-index="${lastManualIndex}"] .queue-rail-remove`);
        await lastRemove.waitFor(); await lastRemove.focus();
        await page.keyboard.press('Tab');
        assert.equal(await page.evaluate(() => document.activeElement?.closest('section')?.getAttribute('aria-label')), 'Up Next',
          'Tab from the final manual entry must mount and focus the first source entry');
        await page.keyboard.press('Shift+Tab');
        assert(await lastRemove.evaluate(element => element === document.activeElement), 'Reverse Tab must return to the final manual remove control');

        await deepScroll('desktop-manual-queue-scroll', '.queue-rail .queue-rail-row', '.queue-rail-list');
        const visibleManual = manual.locator('.virtual-row').filter({ has: page.locator('.queue-rail-row') }).nth(8);
        const removeIndex = Number(await visibleManual.getAttribute('data-virtual-index'));
        const beforeRemove = fixture.state.context.queued_tracks.map(track => track.id);
        await visibleManual.locator('.queue-rail-remove').focus();
        await page.keyboard.press('Enter');
        await waitUntil(() => fixture.state.context.queued_tracks.length === beforeRemove.length - 1, 'Keyboard Remove must not play the row');
        assert.deepEqual(fixture.state.context.queued_tracks.map(track => track.id), beforeRemove.filter((_, index) => index !== removeIndex));

        const playRow = manual.locator('.virtual-row').nth(8);
        const playIndex = Number(await playRow.getAttribute('data-virtual-index'));
        const beforePlay = fixture.state.context.queued_tracks.map(track => track.id);
        await playRow.locator('.queue-rail-row').focus();
        await page.keyboard.press('Enter');
        await waitUntil(() => fixture.state.track.id === beforePlay[playIndex], 'Scrolled manual row used the rendered index instead of its global queue index');
        assert.deepEqual(fixture.state.context.queued_tracks.map(track => track.id), beforePlay.slice(playIndex + 1));

        await rail.locator('.queue-rail-list').evaluate(element => { element.scrollTop = element.scrollHeight; });
        const last = rail.getByRole('button', { name: 'Play Sample track 2000', exact: true });
        await last.waitFor();
        await last.focus(); await page.keyboard.press('Enter');
        await waitUntil(() => fixture.state.track.id === 'sample-1999', 'Scrolled source row did not play its global index');
        assert.equal(fixture.state.context.playback_index, 1999);
        assert.equal(fixture.state.context.queued_tracks.length, 0);
        assert.equal(fixture.audioRequests, 0, 'Remote queue operations must not start local audio');
        scenario.checks.desktopQueueInteractions = 'duplicates, pointer reorder, scrolled keyboard remove/play, global source index';
        await page.setViewportSize({ width: 1024, height: 960 });
        await waitUntil(async () => await rail.count() === 0, 'Hidden rail remained mounted after resize');
        await page.setViewportSize({ width, height: 960 });
        await desktopPlayerChecks();
      }
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
      assert(!overflow, 'Page overflows horizontally');
      assert.deepEqual(scenario.errors, [], 'Unhandled browser errors');
      assert.deepEqual(scenario.issues, [], 'Layout and interaction failures');
    } catch (error) {
      fixture.releaseCommand();
      fixture.releaseAudioDownloads();
      scenario.fixtureDiagnostics = { commands: fixture.commands, currentTrack: fixture.state.track?.id ?? null,
        queueLength: fixture.state.context.queued_tracks.length, queuedIDs: fixture.state.context.queued_tracks.slice(0, 30).map(track => track.id),
        mutations: fixture.mutations, audioRequests: fixture.audioRequests };
      if (songGestureOnly) scenario.gestureEvents = await page.evaluate(() => window.__songGestureEvents).catch(() => []);
      scenario.failure = error.stack ?? String(error);
      report.failures.push({ width, theme, error: scenario.failure });
      await shot('failure').catch(() => {});
    } finally {
      await context.close();
      if (profileDirectory) await fs.rm(profileDirectory, { recursive: true, force: true });
    }
    console.log(`${scenario.failure ? 'FAIL' : 'PASS'} ${width}px ${theme}: ${Object.keys(scenario.checks).join(', ')}`);
  }
} finally {
  await browser.close();
  if (server) await new Promise((resolve) => server.close(resolve));
  await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(`Screenshots and report: ${output}`);
if (report.failures.length) process.exitCode = 1;
