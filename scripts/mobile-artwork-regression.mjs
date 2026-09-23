#!/usr/bin/env node
// Real browser rendering, generated covers, isolated authentication and HTTP state.
// PLAYWRIGHT_MODULE=/installed/playwright/index.mjs node scripts/mobile-artwork-regression.mjs [build-dir] [output-dir]
// Optional BROWSER=chromium (default webkit), BROWSER_PATH=/path/to/chromium.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const playwright = await import(moduleName.startsWith('/') ? pathToFileURL(moduleName).href : moduleName);
const browserName = process.env.BROWSER ?? 'webkit';
assert(['webkit', 'chromium'].includes(browserName), 'BROWSER must be webkit or chromium');
const build = path.resolve(process.argv[2] ?? 'build');
const output = path.resolve(process.argv[3] ?? '/tmp/codec-mobile-artwork-regression');
await fs.mkdir(output, { recursive: true });
const report = { browser: browserName, checks: [], errors: [], expectedCorsErrors: [] };
let origin, externalOrigin, account = 'A', version = 1, externalCover = false, clockOffset = 0;
let tokenNumber = 0, libraryReads = 0, holdOldCover = false;
const streamTokens = new Map(), subscribers = new Set(), heldCovers = [], artRequests = [], externalRequests = [];
const coverBehaviors = new Map(), heldVersions = new Map();
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
function serveArt(response, owner, color) {
  response.writeHead(200, { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'no-store' });
  response.end(`<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect width="128" height="128" fill="${color ?? (owner === 'A' ? '#cc3344' : '#22aa66')}"/></svg>`);
}
function releaseVersion(coverVersion, color = '#cc3344') {
  const held = heldVersions.get(coverVersion) ?? [];
  assert(held.length > 0, `Version ${coverVersion} must have a held response`);
  heldVersions.delete(coverVersion);
  for (const { response, owner } of held) if (!response.destroyed) serveArt(response, owner, color);
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
        const coverVersion = Number(url.searchParams.get('v'));
        const behavior = pathname.includes('/tracks/0/') ? coverBehaviors.get(coverVersion) : null;
        if (behavior?.kind === 'held') {
          const held = heldVersions.get(coverVersion) ?? [];
          held.push({ response, owner }); heldVersions.set(coverVersion, held); return;
        }
        if (behavior?.kind === 'missing') return json({ error: 'Deliberately missing fixture artwork' }, 404);
        if (behavior?.kind === 'corrupt') {
          response.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
          response.end(Buffer.from('This deliberately corrupt fixture cannot decode as PNG.')); return;
        }
        if (behavior?.color) return serveArt(response, owner, behavior.color);
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
const browser = await playwright[browserName].launch({ headless: true,
  ...(browserName === 'chromium' && process.env.BROWSER_PATH ? { executablePath: process.env.BROWSER_PATH } : {}) });
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
        const pending = [...document.querySelectorAll('.artwork-image')].filter(wrapper => {
          const rect = wrapper.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth && wrapper.getAttribute('data-artwork-state') !== 'ready';
        });
        if (incomplete.length || pending.length) window.__artFrames.push([
          ...incomplete.map(image => ({ className: image.className, complete: image.complete, width: image.naturalWidth, sourceKind: image.currentSrc.split(':')[0],
            painted: getComputedStyle(image).visibility === 'visible' && Number(getComputedStyle(image).opacity) > 0 })),
          ...pending.map(wrapper => ({ className: wrapper.className, state: wrapper.getAttribute('data-artwork-state') }))
        ]);
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
  if (desktop) await page.locator('.player .artwork-image').waitFor({ state: 'attached' });
  else await page.getByRole('button', { name: /^Open Now Playing:/ }).waitFor();
  return { page, context };
}
const tab = (page, name) => page.getByRole('navigation', { name: 'Mobile navigation' }).getByRole('button', { name, exact: true });
async function coversReady(page) {
  await page.waitForFunction(() => {
    const images = [...document.images].filter(image => { const rect = image.getBoundingClientRect(); return !image.closest(".artwork-atmosphere") && rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight; });
    const wrappers = [...document.querySelectorAll('.artwork-image')].filter(wrapper => {
      const rect = wrapper.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
    });
    return wrappers.length > 0 && wrappers.every(wrapper => wrapper.getAttribute('data-artwork-state') === 'ready') &&
      images.length > 0 && images.every(image => image.complete && image.naturalWidth > 0 && image.currentSrc.startsWith('blob:'));
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
const primaryCover = desktop => desktop ? '.player .artwork-image' : '.mobile-mini-player .artwork-image';
async function paintFrames(page) {
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}
async function artworkState(page, selector, expected) {
  await page.waitForFunction(({ selector, expected }) => {
    const wrapper = document.querySelector(selector);
    if (wrapper?.getAttribute('data-artwork-state') !== expected) return false;
    if (expected !== 'ready') return true;
    const image = wrapper.querySelector('img');
    return image?.complete && image.naturalWidth > 0;
  }, { selector, expected });
  await paintFrames(page);
  const details = await page.locator(selector).first().evaluate(wrapper => {
    const painted = element => {
      if (!element) return false;
      const rect = element.getBoundingClientRect();
      if (!rect.width || !rect.height || rect.bottom <= 0 || rect.top >= innerHeight || rect.right <= 0 || rect.left >= innerWidth) return false;
      for (let node = element; node instanceof Element; node = node.parentElement) {
        const style = getComputedStyle(node);
        if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
      }
      return true;
    };
    return {
      state: wrapper.getAttribute('data-artwork-state'),
      placeholderPainted: painted(wrapper.querySelector('svg')),
      paintedImages: [...wrapper.querySelectorAll('img')].filter(painted).map(image => ({ complete: image.complete, width: image.naturalWidth })),
      width: wrapper.getBoundingClientRect().width, height: wrapper.getBoundingClientRect().height
    };
  });
  assert.equal(details.state, expected);
  assert(details.width > 0 && details.height > 0, 'Artwork must preserve its layout box');
  if (expected !== 'ready') {
    assert(details.placeholderPainted, `${expected} artwork must show its placeholder`);
    assert.equal(details.paintedImages.length, 0, `${expected} artwork must not paint a broken or stale image`);
  } else {
    assert.equal(details.paintedImages.length, 1, 'Ready artwork must paint its decoded image');
    assert(!details.placeholderPainted, 'Ready artwork must replace the placeholder');
  }
  return details;
}
async function noPaintedBrokenImages(page) {
  const broken = await page.locator('.artwork-image img').evaluateAll(images => images.filter(image => {
    const rect = image.getBoundingClientRect();
    if (!rect.width || !rect.height || rect.bottom <= 0 || rect.top >= innerHeight || rect.right <= 0 || rect.left >= innerWidth) return false;
    for (let node = image; node instanceof Element; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0) return false;
    }
    return !image.complete || image.naturalWidth === 0;
  }).map(image => ({ parent: image.parentElement.className, sourceKind: image.currentSrc.split(':')[0] })));
  assert.deepEqual(broken, [], 'No visible artwork may expose an incomplete or broken image');
}
async function coverPixel(page, selector) {
  return page.locator(`${selector} img`).first().evaluate(image => {
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0, 1, 1);
    return [...context.getImageData(0, 0, 1, 1).data];
  });
}
async function loadingAndErrors(desktop) {
  const family = desktop ? 'desktop' : 'mobile', base = desktop ? 200 : 100;
  externalCover = false; version = base; coverBehaviors.set(version, { kind: 'held' });
  const fixture = await newPage(!desktop, desktop); page = fixture.page;
  const selector = primaryCover(desktop);
  await until(() => (heldVersions.get(base)?.length ?? 0) > 0);
  const loading = await artworkState(page, selector, 'loading'); await noPaintedBrokenImages(page);
  await page.screenshot({ path: path.join(output, `${family}-artwork-loading.png`) });
  await page.evaluate(() => { document.querySelectorAll('[data-theme]').forEach(node => { node.dataset.theme = 'paper'; }); });
  await artworkState(page, selector, 'loading');
  await page.screenshot({ path: path.join(output, `${family}-artwork-loading-paper.png`) });
  await page.evaluate(() => { document.querySelectorAll('[data-theme]').forEach(node => { node.dataset.theme = 'graphite'; }); });
  releaseVersion(base); await artworkState(page, selector, 'ready');
  report.checks.push({ name: `${family}: held cover shows placeholder without painting a broken image`, loading });

  for (const [offset, kind] of [[1, 'missing'], [2, 'corrupt']]) {
    version = base + offset; coverBehaviors.set(version, { kind });
    await refreshLibrary(); const error = await artworkState(page, selector, 'error');
    await noPaintedBrokenImages(page);
    await page.screenshot({ path: path.join(output, `${family}-artwork-${kind === 'missing' ? '404' : 'corrupt'}.png`) });
    report.checks.push({ name: `${family}: ${kind === 'missing' ? 'HTTP 404' : 'corrupt image'} shows stable error placeholder`, error });
  }

  version = base + 3; coverBehaviors.set(version, { color: '#2244cc' });
  await refreshLibrary(); await artworkState(page, selector, 'ready'); await noPaintedBrokenImages(page);
  const recovered = await coverPixel(page, selector);
  assert(recovered[2] > recovered[0] * 2 && recovered[2] > recovered[1] * 2, 'A changed source/version must replace the error state with the new blue cover');
  await page.screenshot({ path: path.join(output, `${family}-artwork-recovered.png`) });
  report.checks.push({ name: `${family}: changed source/version recovers after failed artwork`, pixel: recovered });

  const sourceA = base + 4, sourceB = base + 5;
  version = sourceA; coverBehaviors.set(version, { kind: 'held' });
  await refreshLibrary(); await until(() => (heldVersions.get(sourceA)?.length ?? 0) > 0);
  await artworkState(page, selector, 'loading');
  version = sourceB; coverBehaviors.set(version, { color: '#22aa66' });
  await refreshLibrary(); await artworkState(page, selector, 'ready');
  const winner = await coverPixel(page, selector);
  assert(winner[1] > winner[0] * 2 && winner[1] > winner[2], 'New source B must display before A completes');
  const lateResponse = page.waitForResponse(response => {
    const url = new URL(response.url());
    return url.pathname === '/api/v1/tracks/0/artwork' && Number(url.searchParams.get('v')) === sourceA;
  });
  releaseVersion(sourceA, '#cc3344'); await lateResponse; await paintFrames(page);
  await artworkState(page, selector, 'ready'); await noPaintedBrokenImages(page);
  assert.deepEqual(await coverPixel(page, selector), winner, 'Late red source A must not replace already-visible green source B');
  report.checks.push({ name: `${family}: late source A cannot replace source B`, pixel: winner });

  // Renew the URL credential while the same decoded cover is older than the
  // cache's ten-minute freshness window. Failure must not replace usable art.
  const cachedBlob = await page.locator(`${selector} img`).first().getAttribute('src');
  assert(cachedBlob?.startsWith('blob:'));
  const beforeRefreshTokens = tokenNumber;
  const versionRequests = () => artRequests.filter(request => request.path === '/api/v1/tracks/0/artwork' && Number(request.version) === sourceB).length;
  const beforeRevalidation = versionRequests();
  coverBehaviors.set(sourceB, { kind: 'missing' });
  await page.evaluate(({ selector, cachedBlob }) => {
    window.__watchRevalidation = true; window.__revalidationFrames = [];
    const frame = () => {
      if (!window.__watchRevalidation) return;
      const wrapper = document.querySelector(selector), image = wrapper?.querySelector('img');
      if (wrapper?.getAttribute('data-artwork-state') !== 'ready' || image?.getAttribute('src') !== cachedBlob || !image?.complete || !image?.naturalWidth) {
        window.__revalidationFrames.push({ state: wrapper?.getAttribute('data-artwork-state'), sourceKind: image?.getAttribute('src')?.split(':')[0], width: image?.naturalWidth });
      }
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }, { selector, cachedBlob });
  const failedRefresh = page.waitForResponse(response => {
    const url = new URL(response.url());
    return url.pathname === '/api/v1/tracks/0/artwork' && Number(url.searchParams.get('v')) === sourceB && response.status() === 404;
  });
  clockOffset += 10 * 60_000 + 1000;
  await page.evaluate(offset => { window.__clockOffset = offset; }, clockOffset);
  await refreshLibrary(); await until(() => tokenNumber > beforeRefreshTokens);
  await failedRefresh;
  // Observe several paints after rejection so a plain-image fallback cannot
  // briefly fail and escape the final ready/pixel assertion.
  for (let frame = 0; frame < 4; frame++) await paintFrames(page);
  const revalidationFrames = await page.evaluate(() => { window.__watchRevalidation = false; return window.__revalidationFrames; });
  assert.deepEqual(revalidationFrames, [], 'Failed revalidation must keep the mounted decoded cover ready on every observed frame');
  await artworkState(page, selector, 'ready'); await noPaintedBrokenImages(page);
  assert.equal(await page.locator(`${selector} img`).first().getAttribute('src'), cachedBlob, 'Failed revalidation must retain the existing blob URL');
  assert.deepEqual(await coverPixel(page, selector), winner);
  assert.equal(versionRequests() - beforeRevalidation, 1, 'Failure must make only the revalidation fetch, with no raw image fallback or retry');
  report.checks.push({ name: `${family}: stale-cache revalidation failure retains the decoded cover after token renewal`, revalidationRequests: versionRequests() - beforeRevalidation, blankFrames: revalidationFrames.length });
  await fixture.context.close();
}
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
  assert(blankFrames.every(frame => frame.every(image => !image.painted)), 'Warm remounts must never paint an unloaded image');
  // WebKit already decoded every warm remount before the next frame. Chromium's
  // baseline defers some cached image loads; those frames must show our surface,
  // never the browser's broken image glyph, and must not make another request.
  if (browserName === 'webkit') assert.deepEqual(blankFrames, [], 'WebKit warm remounts must not flash placeholders');
  report.checks.push({ name: 'Home, Library, Songs, Now Playing and Queue reuse covers without refetching or painting broken images across three tours', artworkRequests: warmed, loadingFrames: blankFrames.length, paintedBrokenFrames: 0 });

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
  await desktop.context.close();
  await loadingAndErrors(false); await loadingAndErrors(true);
  assert.deepEqual(report.errors, []); report.passed = true;
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
