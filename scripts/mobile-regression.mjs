#!/usr/bin/env node
// Usage and runtime configuration: scripts/mobile-regression.md
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
  let artworkRequests = 0;
  let received = 0;
  let release;
  let gate;
  return {
    tracks, library, commands, mutations,
    get audioRequests() { return audioRequests; },
    get artworkRequests() { return artworkRequests; },
    get state() { return state; },
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
      if (pathname === '/api/v1/library') return route.fulfill({ json: library });
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
      if (pathname.includes('/audio')) { audioRequests += 1; return route.fulfill({ contentType:'audio/wav', body:wave }); }
      const playlistMatch = pathname.match(/^\/api\/v1\/playlists\/([^/]+)\/tracks(?:\/([^/]+))?$/);
      if (playlistMatch) {
        const playlist = playlists.find(p => p.id === decodeURIComponent(playlistMatch[1]));
        if (!playlist) return route.fulfill({status:404,json:{error:'Unknown fixture playlist'}});
        const body = request.method() === 'DELETE' ? null : request.postDataJSON();
        mutations.push({method:request.method(),playlist:playlist.id,body});
        if (request.method() === 'PUT') playlist.track_ids = [...body.track_ids];
        else if (request.method() === 'POST') { const track = tracks.find(t=>t.fingerprint===body.fingerprint); if(track && !playlist.track_ids.includes(track.id))playlist.track_ids.push(track.id); }
        else if (request.method() === 'DELETE') playlist.track_ids = playlist.track_ids.filter(id=>id!==decodeURIComponent(playlistMatch[2]));
        return route.fulfill({json:playlist});
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
    const scenario = { width, theme, mobile, screenshots: [], errors: [], consoleErrors: [], issues: [], checks: {} };
    report.scenarios.push(scenario);
    const context = await browser.newContext({ viewport: { width, height: mobile ? 844 : 960 }, deviceScaleFactor: mobile ? 2 : 1, isMobile: mobile, hasTouch: mobile, serviceWorkers: 'block' });
    await context.addInitScript((theme) => {
      localStorage.setItem('codec.theme', theme);
      localStorage.setItem('codec.syncServer', location.origin);
      localStorage.setItem('codec.deviceId', 'fixture-browser');
    }, theme);
    const fixture = fixtures(new URL(baseURL).origin);
    const page = await context.newPage();
    page.on('pageerror', (error) => scenario.errors.push(error.stack ?? error.message));
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
      }
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
      assert(!overflow, 'Page overflows horizontally');
      assert.deepEqual(scenario.errors, [], 'Unhandled browser errors');
      assert.deepEqual(scenario.issues, [], 'Layout and interaction failures');
    } catch (error) {
      fixture.releaseCommand();
      scenario.failure = error.stack ?? String(error);
      report.failures.push({ width, theme, error: scenario.failure });
      await shot('failure').catch(() => {});
    } finally { await context.close(); }
    console.log(`${scenario.failure ? 'FAIL' : 'PASS'} ${width}px ${theme}: ${Object.keys(scenario.checks).join(', ')}`);
  }
} finally {
  await browser.close();
  if (server) await new Promise((resolve) => server.close(resolve));
  await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
}
console.log(`Screenshots and report: ${output}`);
if (report.failures.length) process.exitCode = 1;
