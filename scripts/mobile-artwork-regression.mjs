#!/usr/bin/env node
// Real mobile WebKit, generated covers, isolated authentication and HTTP state.
// PLAYWRIGHT_MODULE=/installed/playwright/index.mjs node scripts/mobile-artwork-regression.mjs [build-dir] [output-dir]
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const { webkit } = await import(moduleName.startsWith('/') ? pathToFileURL(moduleName).href : moduleName);
const build = path.resolve(process.argv[2] ?? 'build');
const output = path.resolve(process.argv[3] ?? '/tmp/codec-mobile-artwork-regression');
await fs.mkdir(output, { recursive: true });
const report = { browser: 'WebKit', checks: [], errors: [], expectedCorsErrors: [] };
let origin, externalOrigin, account = 'A', version = 1, externalCover = false, clockOffset = 0;
let tokenNumber = 0, libraryReads = 0, holdOldCover = false;
const streamTokens = new Map(), subscribers = new Set(), heldCovers = [], artRequests = [], externalRequests = [];
const wav = Buffer.alloc(44 + 16000);
wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8); wav.writeUInt32LE(16, 16);
wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(8000, 24); wav.writeUInt32LE(16000, 28);
wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write('data', 36); wav.writeUInt32LE(16000, 40);
const reference = index => ({ id: `track_${index}`, path: `loud://track/${index}`, fingerprint: String(index) });
const tracks = () => [0, 1, 2].map(index => ({
  ...reference(index), file_name: `${index}.wav`, title: ['First cover', 'Second cover', 'Third cover'][index],
  artist: 'Artwork fixture', album: `Single ${index}`, duration_seconds: 300,
  artwork_url: index === 2 && externalCover ? `${externalOrigin}/cover.svg` : `${origin}/api/v1/tracks/${index}/artwork?v=${index === 0 ? version : 1}`,
  playlist_ids: ['mix', 'collage'], is_liked: false, added_at: 1700000000 + index, size_bytes: wav.length
}));
const library = () => ({
  root_path: 'loud://fixture', scanned_at: libraryReads, tracks: tracks(), artists: [], albums: [],
  playlists: [
    { id: 'mix', name: 'Custom cover', track_ids: [0, 1, 2].map(i => reference(i).id), artwork_url: `${origin}/api/v1/playlists/mix/artwork?v=1`, is_liked: false },
    { id: 'collage', name: 'Collage cover', track_ids: [0, 1, 2].map(i => reference(i).id), artwork_url: null, is_liked: false }
  ], stats: { trackCount: 3, playlistCount: 2, likedCount: 0, artistCount: 1, albumCount: 3, durationSeconds: 900 }
});
let state = { schema: 'loud.playback.v2', revision: 1, active_device_id: 'art-browser', state: 'paused', track: reference(0),
  context: { playback_source: [0, 1, 2].map(reference), playback_index: 0, queued_tracks: [1, 2].map(reference), play_history: [], shuffle: false, repeat: 'off' },
  clock: { position_seconds: 0, started_at_ms: null, updated_at_ms: Date.now() }, volume: .6, server_time_ms: Date.now() };
const snapshot = () => ({ ...state, server_time_ms: Date.now() + clockOffset });
const publishLibrary = () => { for (const response of subscribers) response.write('event: library\ndata: {"type":"library"}\n\n'); };
function serveArt(response, owner) {
  response.writeHead(200, { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'no-store' });
  response.end(`<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect width="128" height="128" fill="${owner === 'A' ? '#cc3344' : '#22aa66'}"/></svg>`);
}
const externalServer = http.createServer((request, response) => {
  externalRequests.push({ url: request.url, mode: request.headers['sec-fetch-mode'] ?? 'unknown', authorization: request.headers.authorization ?? null });
  serveArt(response, 'B');
});
await new Promise(resolve => externalServer.listen(0, '127.0.0.1', resolve));
externalOrigin = `http://127.0.0.1:${externalServer.address().port}`;
const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, origin ?? 'http://127.0.0.1'), pathname = url.pathname;
    const json = (body, status = 200) => { response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); response.end(JSON.stringify(body)); };
    if (pathname === '/health') return json({ ok: true, schema: 'loud.sync.v1', playback_schema: 'loud.playback.v2', server_id: 'artwork-fixture' });
    if (pathname.startsWith('/api/')) {
      const token = request.headers.authorization?.replace(/^Bearer /, '') ?? url.searchParams.get('access_token');
      const owner = streamTokens.get(token) ?? (/^fixture-auth-[AB]$/.test(token ?? '') ? token.at(-1) : null);
      if (pathname.endsWith('/artwork')) artRequests.push({ path: pathname, version: url.searchParams.get('v'), owner, account, accepted: owner === account });
      if (owner !== account) return json({ error: 'Fixture authorization required' }, 401);
      if (pathname === '/api/v1/auth/stream-token') {
        const token = `stream_fixture_${account}_${++tokenNumber}`; streamTokens.set(token, account);
        return json({ token, expires_at: (Date.now() + clockOffset) / 1000 + 90 });
      }
      if (pathname === '/api/v1/library') { libraryReads++; return json(library()); }
      if (pathname === '/api/v2/playback') return json(snapshot());
      if (pathname === '/api/v2/playback/events') {
        response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
        subscribers.add(response); request.on('close', () => subscribers.delete(response));
        response.write(`event: playback_state\ndata: ${JSON.stringify({ type: 'playback_state', playback_state: snapshot() })}\n\n`); return;
      }
      if (pathname.includes('/devices')) return json(request.method === 'GET' ? [{ device_id: 'art-browser', name: 'This browser', updated_at: Date.now() + clockOffset }] : {});
      if (pathname === '/api/v2/playback/commands') {
        let body = ''; for await (const part of request) body += part;
        const command = JSON.parse(body);
        state = { ...state, revision: state.revision + 1, volume: command.volume ?? state.volume };
        return json(snapshot());
      }
      if (pathname.endsWith('/artwork')) {
        if (holdOldCover && owner === 'A' && pathname.includes('/tracks/0/')) { heldCovers.push(response); return; }
        return serveArt(response, owner);
      }
      if (pathname.endsWith('/audio')) { response.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': wav.length }); response.end(wav); return; }
      return json([]);
    }
    const filename = path.resolve(build, '.' + (pathname === '/' ? '/index.html' : decodeURIComponent(pathname)));
    if (!filename.startsWith(build + path.sep)) { response.writeHead(403).end(); return; }
    const bytes = await fs.readFile(filename);
    response.writeHead(200, { 'Content-Type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.ttf': 'font/ttf' })[path.extname(filename)] ?? 'application/octet-stream' }); response.end(bytes);
  } catch { if (!response.headersSent) response.writeHead(404); response.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); origin = `http://127.0.0.1:${server.address().port}`;
const browser = await webkit.launch({ headless: true });
async function newPage(iphone, desktop = false) {
  const context = await browser.newContext({ viewport: desktop ? { width: 1440, height: 900 } : { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: !desktop, hasTouch: !desktop, serviceWorkers: 'block',
    ...(iphone ? { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' } : {}) });
  await context.addInitScript(({ account }) => {
    localStorage.setItem('codec.syncServer', location.origin); localStorage.setItem('codec.syncToken', `fixture-auth-${account}`);
    localStorage.setItem('codec.deviceId', 'art-browser'); localStorage.setItem('codec.theme', 'graphite');
    const originalNow = Date.now; window.__clockOffset = 0; Date.now = () => originalNow() + window.__clockOffset;
    window.__artFrames = []; window.__recordArt = false;
    const frame = () => {
      if (window.__recordArt) {
        const images = [...document.images].filter(image => { const rect = image.getBoundingClientRect(); return !image.closest(".artwork-atmosphere") && rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight; });
        const incomplete = images.filter(image => !image.complete || !image.naturalWidth || !image.currentSrc.startsWith('blob:'));
        if (incomplete.length) window.__artFrames.push(incomplete.map(image => ({ className: image.className, complete: image.complete, width: image.naturalWidth, sourceKind: image.currentSrc.split(':')[0] })));
      }
      requestAnimationFrame(frame);
    }; requestAnimationFrame(frame);
  }, { account });
  const page = await context.newPage(); page.setDefaultTimeout(10000);
  page.on('pageerror', error => {
    // WebKit surfaces deliberately denied fixture CORS as pageerrors even when
    // the application catches fetch rejection and displays the normal image.
    const expected = error.message.includes(`${new URL(externalOrigin).host}/cover.svg`) && error.message.endsWith('due to access control checks.');
    (expected ? report.expectedCorsErrors : report.errors).push(error.message);
  });
  await page.route('**/*', route => [origin, externalOrigin].includes(new URL(route.request().url()).origin) ? route.continue() : route.abort());
  await page.goto(origin);
  if (desktop) await page.locator('.player img').waitFor();
  else await page.getByRole('button', { name: /^Open Now Playing:/ }).waitFor();
  return { page, context };
}
const tab = (page, name) => page.getByRole('navigation', { name: 'Mobile navigation' }).getByRole('button', { name, exact: true });
async function coversReady(page) {
  await page.waitForFunction(() => {
    const images = [...document.images].filter(image => { const rect = image.getBoundingClientRect(); return !image.closest(".artwork-atmosphere") && rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight; });
    return images.length > 0 && images.every(image => image.complete && image.naturalWidth > 0 && image.currentSrc.startsWith('blob:'));
  });
}
async function tour(page) {
  await tab(page, 'Library').tap(); await coversReady(page);
  const songs = page.getByRole('button', { name: /^Songs\b/ });
  if (await songs.count()) await songs.tap();
  await coversReady(page);
  await page.getByRole('button', { name: /^Open Now Playing:/ }).tap(); await coversReady(page);
  await page.getByRole('button', { name: 'Queue', exact: true }).tap(); await coversReady(page);
  await page.getByRole('dialog', { name: 'Queue', exact: true }).getByRole('button', { name: 'Done', exact: true }).tap();
  await page.getByRole('dialog', { name: 'Queue', exact: true }).waitFor({ state: 'detached' });
  await page.getByRole('button', { name: 'Close Now Playing', exact: true }).tap();
  await page.getByRole('dialog', { name: 'Now Playing', exact: true }).waitFor({ state: 'detached' });
  await tab(page, 'Home').tap(); await coversReady(page);
}
async function until(predicate) {
  const deadline = Date.now() + 10000;
  while (!await predicate()) { assert(Date.now() < deadline, 'Fixture condition timed out'); await new Promise(resolve => setTimeout(resolve, 15)); }
}
async function refreshLibrary() { const before = libraryReads; publishLibrary(); await until(() => libraryReads > before); }
let page;
try {
  const first = await newPage(true); page = first.page;
  await coversReady(page); await tour(page);
  const warmed = artRequests.length;
  assert.equal(warmed, 4, 'Three track covers and one custom cover are fetched only once, including color sampling');
  await page.evaluate(() => { window.__recordArt = true; });
  for (let index = 0; index < 3; index++) await tour(page);
  const blankFrames = await page.evaluate(() => { window.__recordArt = false; return window.__artFrames; });
  assert.equal(artRequests.length, warmed, 'Tab, player and queue remounts must not refetch covers');
  assert.deepEqual(blankFrames, [], 'Warm remounts must not paint unloaded covers');
  report.checks.push({ name: 'Home, Library, Songs, Now Playing and Queue reuse decoded blob covers across three tours', artworkRequests: warmed, blankFrames: blankFrames.length });

  const beforeTokens = tokenNumber;
  clockOffset += 31000; await page.evaluate(offset => { window.__clockOffset = offset; }, clockOffset);
  await refreshLibrary(); await until(() => tokenNumber > beforeTokens); await tour(page);
  assert.equal(artRequests.length, warmed, 'Stream token rotation must preserve cover cache identity');
  report.checks.push({ name: 'Stream token rotation reuses all existing artwork', artworkRequests: artRequests.length });

  const oldBlob = await page.locator('.mobile-mini-player img').getAttribute('src');
  version = 2; await refreshLibrary();
  await page.waitForFunction(old => { const image = document.querySelector('.mobile-mini-player img'); return image?.complete && image.naturalWidth > 0 && image.src !== old; }, oldBlob);
  assert.equal(artRequests.length, warmed + 1, 'Cover version change fetches exactly the changed cover');
  report.checks.push({ name: 'Versioned replacement fetches once and updates already-mounted mini player' });

  await page.getByRole('button', { name: /^Open Now Playing:/ }).tap();
  await page.getByRole('dialog', { name: 'Now Playing', exact: true }).waitFor();
  await page.waitForFunction(() => { const dialog = document.querySelector('dialog[aria-label="Now Playing"]'); if (!dialog) return false; const style = getComputedStyle(dialog); return Number(style.opacity) === 1 && (style.transform === 'none' || Math.abs(new DOMMatrixReadOnly(style.transform).m42) < 1); });
  assert.equal(await page.locator('.mobile-now-volume, .volume-control').count(), 0, 'iPhone web has no volume controls or guidance row');
  assert.equal(await page.getByRole('slider', { name: /volume/i }).count(), 0);
  report.checks.push({ name: 'iPhone web omits volume controls and guidance rows' });
  await page.getByRole('button', { name: 'Close Now Playing', exact: true }).tap();
  await page.getByRole('dialog', { name: 'Now Playing', exact: true }).waitFor({ state: 'detached' });

  holdOldCover = true; version = 3; await refreshLibrary(); await until(() => heldCovers.length > 0);
  const oldAccountRequests = artRequests.filter(request => request.owner === 'A').length;
  account = 'B'; await page.getByRole('button', { name: 'Settings', exact: true }).tap();
  const settings = page.getByRole('dialog', { name: 'Settings', exact: true });
  await settings.getByLabel('Auth token', { exact: true }).fill('fixture-auth-B');
  await settings.getByRole('button', { name: 'Reconnect', exact: true }).tap();
  await until(() => artRequests.some(request => request.owner === 'B' && request.path.includes('/tracks/0/')));
  for (const response of heldCovers) serveArt(response, 'A'); holdOldCover = false;
  if (await settings.count()) await settings.getByRole('button', { name: 'Done', exact: true }).tap();
  await settings.waitFor({ state: 'detached' }); await coversReady(page); await page.waitForTimeout(150);
  const pixel = await page.locator('.mobile-mini-player img').evaluate(image => { const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1; const context = canvas.getContext('2d'); context.drawImage(image, 0, 0, 1, 1); return [...context.getImageData(0, 0, 1, 1).data]; });
  assert(pixel[1] > pixel[0], 'New account cover must win over late old account response');
  assert.equal(artRequests.filter(request => request.owner === 'A').length, oldAccountRequests, 'Aborted old account fetch must not fall back to another old-token image request');
  assert(artRequests.filter(request => request.owner === 'B').length >= 1);
  report.checks.push({ name: 'Account change clears artwork, rejects late old results and avoids old-token fallback', pixel });

  externalCover = true; await refreshLibrary(); await tab(page, 'Library').tap();
  const songs = page.getByRole('button', { name: /^Songs\b/ });
  if (await songs.count()) await songs.tap();
  await page.waitForFunction(externalOrigin => [...document.images].some(image => image.src.startsWith(externalOrigin) && image.complete && image.naturalWidth > 0), externalOrigin);
  assert(externalRequests.length >= 2, 'Fixture exercises blocked fetch CORS followed by a normal image load');
  assert(externalRequests.every(request => !new URL(request.url, externalOrigin).searchParams.has('access_token') && request.authorization === null), 'Codec credentials must never be attached to third-party artwork');
  report.checks.push({ name: 'Artwork without fetch CORS still renders through a plain image fallback', requests: externalRequests.length });
  await page.screenshot({ path: path.join(output, 'mobile-artwork.png') });
  await first.context.close();

  const second = await newPage(false); page = second.page;
  await page.getByRole('button', { name: /^Open Now Playing:/ }).tap();
  await page.getByRole('dialog', { name: 'Now Playing', exact: true }).waitFor();
  await page.waitForFunction(() => { const dialog = document.querySelector('dialog[aria-label="Now Playing"]'); if (!dialog) return false; const style = getComputedStyle(dialog); return Number(style.opacity) === 1 && (style.transform === 'none' || Math.abs(new DOMMatrixReadOnly(style.transform).m42) < 1); });
  assert.equal(await page.locator('.mobile-now-volume, .volume-control').count(), 0, 'Non-iOS mobile web has no volume controls');
  assert.equal(await page.getByRole('slider', { name: /volume/i }).count(), 0);
  await page.screenshot({ path: path.join(output, 'mobile-player.png') });
  await second.context.close();

  const desktop = await newPage(false, true); page = desktop.page;
  assert.equal(await page.locator('.mobile-now-volume, .volume-control').count(), 0, 'Desktop web has no volume controls');
  assert.equal(await page.getByRole('slider', { name: /volume/i }).count(), 0);
  report.checks.push({ name: 'Non-iOS mobile and desktop web both omit volume controls' });
  await desktop.context.close(); assert.deepEqual(report.errors, []); report.passed = true;
} catch (error) {
  report.error = error.stack;
  if (page && !page.isClosed()) report.images = await page.locator('img').evaluateAll(images => images.map(image => ({ className: image.className, complete: image.complete, width: image.naturalWidth, sourceKind: image.currentSrc.split(':')[0], atmosphere: Boolean(image.closest('.artwork-atmosphere')) })));
  if (page && !page.isClosed()) { await page.screenshot({ path: path.join(output, 'failure.png') }); await fs.writeFile(path.join(output, 'failure.txt'), await page.locator('body').innerText()); }
  process.exitCode = 1;
} finally {
  report.artworkRequests = artRequests; report.externalRequests = externalRequests; await fs.writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2)); console.log(JSON.stringify(report, null, 2));
  await browser.close(); for (const response of subscribers) response.end();
  server.closeAllConnections(); externalServer.closeAllConnections();
  await Promise.all([new Promise(resolve => server.close(resolve)), new Promise(resolve => externalServer.close(resolve))]);
}
