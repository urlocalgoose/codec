#!/usr/bin/env node
// Real browser -> real local-server smoke. No HTTP response fixtures or production URLs.
// Run through bun local:check; its manager lock prevents competing lab CLI operations.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const lab = path.join(repo, '.codec-dev');
const options = new Map();
for (let i = 2; i < process.argv.length; i += 2) {
  assert(['--output-dir', '--browser'].includes(process.argv[i]) && process.argv[i + 1], 'Use --output-dir PATH [--browser chromium|webkit]');
  options.set(process.argv[i], process.argv[i + 1]);
}
const output = path.resolve(options.get('--output-dir') ?? path.join(lab, 'reports', `browser-${Date.now()}`));
const browsers = options.has('--browser') ? [options.get('--browser')] : ['chromium', 'webkit'];
assert(browsers.every(name => ['chromium', 'webkit'].includes(name)), 'Unsupported browser');
assert.equal(await fs.realpath(lab), lab, 'Lab storage must not be symlinked');
const config = JSON.parse(await fs.readFile(path.join(lab, 'config.json'), 'utf8'));
assert.equal(config.schema, 'codec.local-dev.v1');
assert.equal(config.repository, repo, 'Local config belongs to a different checkout');
const servers = {};
for (const name of ['a', 'b']) {
  const port = config.instances?.[name]?.port;
  assert(Number.isInteger(port) && port >= 1024 && port <= 65535 && ![8787, 8788].includes(port), 'Unsafe lab port');
  const tokenPath = path.join(lab, 'instances', name, 'auth-token');
  assert.equal(await fs.realpath(tokenPath), tokenPath, 'Lab auth must not be symlinked');
  const token = (await fs.readFile(tokenPath, 'utf8')).trim();
  assert(token.length >= 20, 'Missing local token');
  servers[name] = { origin: `http://127.0.0.1:${port}`, token };
}
assert.notEqual(servers.a.origin, servers.b.origin, 'Lab servers must be independent');
assert.notEqual(servers.a.token, servers.b.token, 'Lab servers need different credentials');
const allowedOrigins = new Set(Object.values(servers).map(server => server.origin));
const secrets = Object.values(servers).map(server => server.token);
const redact = value => secrets.reduce((result, secret) => result.replaceAll(secret, '[redacted]'), String(value))
  .replace(/([?&](?:access_token|token)=)[^&\s"']+/g, '$1[redacted]');
let playwright;
const candidates = [process.env.PLAYWRIGHT_MODULE, 'playwright',
  path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs')].filter(Boolean);
for (const candidate of candidates) {
  try { playwright = await import(candidate.startsWith('/') || candidate.startsWith('.') ? pathToFileURL(path.resolve(candidate)).href : candidate); break; }
  catch { /* Try the next installed runtime, without downloading dependencies. */ }
}
assert(playwright, 'Install Playwright + Chromium/WebKit in your test environment, or set PLAYWRIGHT_MODULE');
await fs.mkdir(output, { recursive: true, mode: 0o700 });
const report = { schema: 'codec.local-browser-smoke.v1', started_at: new Date().toISOString(),
  origins: [...allowedOrigins], browsers: [], failures: [], limitations: [
    'Desktop WebKit is not physical iPhone Safari or an installed Home Screen app.',
    'Playback stays paused: this checks live state propagation, not audible continuity.',
    'An empty playback baseline finishes with a paused demo song because the public API has no clear-track command.'
  ] };

async function request(name, pathname, { method = 'GET', body, token = servers[name].token, expected = [200], headers = {} } = {}) {
  assert(pathname.startsWith('/api/') || pathname === '/health', 'Only local API paths are supported');
  const response = await fetch(`${servers[name].origin}${pathname}`, { method, redirect: 'error',
    signal: AbortSignal.timeout(10000), headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  assert(expected.includes(response.status), `${name.toUpperCase()} ${method} ${pathname.split('?')[0]} returned ${response.status}`);
  if (response.status === 204 || !(response.headers.get('content-type') ?? '').includes('application/json')) {
    await response.arrayBuffer(); return null;
  }
  return response.json();
}
const library = name => request(name, '/api/v1/library');
const state = name => request(name, '/api/v2/playback');
const reference = track => ({ id: track.id, path: track.path, fingerprint: track.fingerprint });
const emptyContext = () => ({ playback_source: [], playback_index: 0, queued_tracks: [], play_history: [], shuffle: false, repeat: 'off' });
const fingerprintPath = track => encodeURIComponent(track.fingerprint);
async function command(fields, token) {
  const previous = await state('a');
  return request('a', '/api/v2/playback/commands', { method: 'POST', token,
    headers: { 'If-Match': `"${previous?.revision ?? 0}"` },
    body: { command_id: `local-browser-${randomUUID()}`, device_id: 'local-browser-smoke-remote', ...fields } });
}
async function until(check, message, timeout = 12000) {
  const end = Date.now() + timeout;
  while (!await check()) {
    assert(Date.now() < end, message);
    await new Promise(resolve => setTimeout(resolve, 80));
  }
}
function durableLibrary(value) {
  return { tracks: value.tracks.map(track => [track.id, track.is_liked, [...track.playlist_ids].sort()]),
    playlists: value.playlists.map(playlist => [playlist.id, playlist.name, playlist.track_ids, playlist.artwork_url]) };
}
async function restorePlayback(before, demoTrack) {
  const track = before?.track ?? reference(demoTrack);
  await command({ kind: 'load', track, context: before?.context ?? emptyContext(),
    target_device_id: before?.active_device_id ?? 'local-browser-smoke-remote',
    position_seconds: before?.clock?.position_seconds ?? 0, volume: before?.volume ?? 1 });
  // A stopped state cannot be restored exactly through the public command API.
  // Preserve its song/queue/position and leave it paused; never start audio.
}
async function connect(context, name, mobile = false) {
  const page = await context.newPage();
  await page.goto(servers[name].origin);
  await page.getByRole('heading', { name: 'Welcome', exact: true }).waitFor();
  if (mobile) {
    await page.getByRole('button', { name: "I'm confused", exact: true }).click();
    await page.getByRole('heading', { name: 'How Codec works', exact: true }).waitFor();
    assert.equal(await page.getByRole('link', { name: 'Visit the Codec website' }).getAttribute('href'), 'https://codec.codie.sh/');
    assert.equal(await page.getByRole('link', { name: 'Open setup guide' }).getAttribute('href'), 'https://codec.codie.sh/docs/hosting.html');
    await page.getByRole('button', { name: 'I have a server', exact: true }).click();
    await page.getByRole('heading', { name: 'Connect to your library', exact: true }).waitFor();
    await page.getByRole('button', { name: 'Back to welcome', exact: true }).click();
    await page.getByRole('button', { name: 'I need to set one up', exact: true }).click();
    await page.getByRole('heading', { name: 'Set up a server', exact: true }).waitFor();
    assert.equal(await page.getByRole('link', { name: 'Open setup guide' }).getAttribute('href'), 'https://codec.codie.sh/docs/hosting.html');
    await page.getByRole('button', { name: 'I have my server details', exact: true }).click();
    await page.getByRole('textbox', { name: 'Server address' }).fill(servers[name].origin);
    await page.getByLabel('Auth token', { exact: true }).fill('draft-to-preserve');
    await page.getByRole('button', { name: 'Back to welcome', exact: true }).click();
  }
  await page.getByRole('button', { name: 'I have a server', exact: true }).click();
  await page.getByRole('heading', { name: 'Connect to your library' }).waitFor();
  if (mobile) {
    assert.equal(await page.getByRole('textbox', { name: 'Server address' }).inputValue(), servers[name].origin);
    assert.equal(await page.getByLabel('Auth token', { exact: true }).inputValue(), 'draft-to-preserve', 'Back keeps connection drafts');
    assert.equal(await page.locator('#onboarding-title').evaluate(element => element === document.activeElement), true, 'Step navigation focuses its heading');
  }
  await page.getByRole('textbox', { name: 'Server address' }).fill(servers[name].origin);
  await page.getByLabel('Auth token', { exact: true }).fill(servers[name].token);
  await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await page.locator(mobile ? 'nav[aria-label="Mobile navigation"]' : 'aside[aria-label="Library navigation"]').waitFor();
  return page;
}
async function verifyImages(page) {
  await page.waitForFunction(() => [...document.querySelectorAll('.artwork-image img')]
    .some(image => image.complete && image.naturalWidth > 0));
  const broken = await page.locator('.artwork-image[data-artwork-state="error"]').count();
  assert.equal(broken, 0, 'Visible demo artwork must load from the real server');
}

try {
  const healthA = await request('a', '/health', { token: '' });
  const healthB = await request('b', '/health', { token: '' });
  assert(healthA.server_id && healthB.server_id && healthA.server_id !== healthB.server_id, 'Distinct real server IDs required');
  await request('b', '/api/v1/library', { token: servers.a.token, expected: [401] });
  await request('a', '/api/v1/library', { token: servers.b.token, expected: [401] });
  report.authenticationIsolation = 'A and B reject each other’s owner token';
  for (const browserName of browsers) {
    const result = { browser: browserName, checks: [], pageErrors: [], screenshots: [] };
    report.browsers.push(result);
    const originalA = await library('a'), originalB = await library('b');
    const playbackBefore = await state('a'), playbackBBefore = await state('b');
    assert(playbackBefore?.state !== 'playing', 'Pause local server A before browser smoke tests');
    assert(originalA.tracks.length >= 2 && originalB.tracks.length >= 2, 'Seed both local demo servers first');
    const track = originalA.tracks[0], nextTrack = originalA.tracks[1];
    let temporaryPlaylist, aux, guestCredential, browser;
    const contexts = [];
    const cleanupFailures = [];
    try {
      temporaryPlaylist = await request('a', '/api/v1/playlists', { method: 'POST',
        body: { name: `Local browser smoke ${randomUUID().slice(0, 8)}` }, expected: [201] });
      await command({ kind: 'load', track: reference(track), position_seconds: 5,
        context: { ...emptyContext(), playback_source: [reference(track), reference(nextTrack)] } });
      browser = await playwright[browserName].launch({ headless: true,
        ...(browserName === 'chromium' && process.env.PLAYWRIGHT_BROWSER_PATH ? { executablePath: process.env.PLAYWRIGHT_BROWSER_PATH } : {}) });
      async function context(mobile = false) {
        const created = await browser.newContext({ viewport: { width: mobile ? 390 : 1440, height: mobile ? 844 : 960 },
          isMobile: mobile, hasTouch: mobile, serviceWorkers: 'block' });
        created.setDefaultTimeout(12000); contexts.push(created);
        await created.route('**/*', route => {
          // No mocking: permitted requests reach the real local servers.
          const url = new URL(route.request().url());
          return allowedOrigins.has(url.origin) ? route.continue() : route.abort('blockedbyclient');
        });
        created.on('page', page => page.on('pageerror', error => result.pageErrors.push(redact(error.message))));
        await created.addInitScript(() => {
          if (location.hostname === '127.0.0.1') localStorage.setItem('codec.theme', 'graphite');
          // A separate profile has no listening-app/browser state to overwrite.
        });
        return created;
      }
      const desktop = await connect(await context(), 'a');
      const footer = desktop.locator('footer.player[aria-label="Player"]');
      const like = liked => footer.getByRole('button', { name: `${liked ? 'Unlike' : 'Like'} ${track.title}`, exact: true });
      await like(track.is_liked).waitFor();
      await verifyImages(desktop);
      result.checks.push('Desktop owner login, real library and decoded artwork');
      for (const desired of [!track.is_liked, track.is_liked]) {
        await like(!desired).click();
        await until(async () => (await library('a')).tracks.find(item => item.id === track.id)?.is_liked === desired, 'Like must persist on local server A');
        await like(desired).waitFor();
      }
      result.checks.push('Desktop current-song Like and Unlike persist through real API');
      for (const desired of [true, false]) {
        await footer.getByRole('button', { name: `Add ${track.title} to playlist`, exact: true }).click();
        const modal = desktop.getByRole('dialog', { name: `Edit playlists for ${track.title}`, exact: true });
        await modal.locator('label.playlist-choice').filter({ hasText: temporaryPlaylist.name }).click();
        await modal.getByRole('button', { name: 'Save', exact: true }).click();
        await modal.waitFor({ state: 'detached' });
        await until(async () => (await library('a')).playlists.find(item => item.id === temporaryPlaylist.id)?.track_ids.includes(track.id) === desired,
          'Current-song playlist Save must persist to the local server');
      }
      result.checks.push('Desktop playlist membership Save/add/remove persists without changing other playlists');
      const mobile = await connect(await context(true), 'a', true);
      result.checks.push('Welcome branches reach connection/setup/help; Back preserves drafts and focuses the next heading');
      await mobile.getByRole('navigation', { name: 'Mobile navigation' }).getByRole('button', { name: 'Library', exact: true }).click();
      await mobile.locator('.mobile-playlist-row').first().waitFor();
      await verifyImages(mobile);
      assert(await mobile.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'Mobile library must fit its viewport');
      result.checks.push('390px mobile owner login, playlist list and actual decoded covers');
      await command({ kind: 'load', track: reference(nextTrack), position_seconds: 11,
        context: { ...emptyContext(), playback_source: [reference(track), reference(nextTrack)], playback_index: 1 } });
      await footer.getByRole('button', { name: `Add ${nextTrack.title} to playlist`, exact: true }).waitFor();
      await mobile.getByRole('button', { name: `Open Now Playing: ${nextTrack.title}`, exact: true }).waitFor();
      assert.equal((await state('a')).state, 'paused', 'Remote state changes must not start audio');
      result.checks.push('One real remote playback command reaches desktop and mobile through live sync while paused');
      // Legacy Aux is intentionally retired; ordinary owner APIs above remain
      // the installed-client contract. This is not a permissive v1 fallback.
      await request('a', '/api/v1/aux', { method: 'POST', body: {}, expected: [410] });
      await request('a', '/api/v1/aux/join', { method: 'POST', token: '', body: { code: 'OLD1' }, expected: [410] });
      const ownerBeforeAux = await state('a');
      assert((await request('a', '/api/v2/aux/sessions')).sessions.length === 0, 'End existing local Aux before smoke tests');
      aux = await request('a', '/api/v2/aux/sessions', { method: 'POST', expected: [201], body: {
        mode: 'shared_speaker', host_device_id: ownerBeforeAux.active_device_id,
        host_name: 'Local browser Aux', catalog_fingerprints: originalA.tracks.map(item => item.fingerprint),
        allow_saves: false, allow_contributions: false
      } });
      secrets.push(aux.invite_secret);
      if (aux.state.media_token) secrets.push(aux.state.media_token);
      const auxPath = `/api/v2/aux/sessions/${encodeURIComponent(aux.session_id)}`;
      const guest = await (await context()).newPage();
      await guest.addInitScript(() => {
        window.__codecSmokePlayCalls = 0;
        const play = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function (...args) { window.__codecSmokePlayCalls++; return play.apply(this, args); };
      });
      await guest.goto(`${servers.a.origin}/#aux=${encodeURIComponent(aux.invite_secret)}`);
      await guest.getByRole('heading', { name: 'Join Aux', exact: true }).waitFor();
      assert.equal(await guest.evaluate(() => localStorage.getItem('codec.aux.v2.connection')), null,
        'Invitation must wait for an explicit browser join');
      const joining = guest.waitForResponse(response => new URL(response.url()).pathname === '/api/v2/aux/join' && response.request().method() === 'POST');
      await guest.getByRole('button', { name: 'Join in this browser', exact: true }).click();
      const joinedResponse = await joining;
      assert.equal(joinedResponse.status(), 200, 'Explicit browser join must exchange the invitation');
      guestCredential = await joinedResponse.json();
      secrets.push(guestCredential.participant_token);
      await guest.getByRole('button', { name: 'Leave Aux', exact: true }).waitFor();
      assert.equal(new URL(guest.url()).hash, '', 'Invitation secret must leave visible browser history');
      assert.equal(await guest.locator('footer.player, .player-track-actions').count(), 0, 'Dedicated Aux must not expose owner library controls');
      assert.equal(await guest.evaluate(() => localStorage.getItem('codec.syncToken')), null, 'Guest credential must not replace the owner login slot');
      for (const endpoint of ['/api/v1/library', '/api/v1/playback/devices', '/api/v2/playback']) {
        await request('a', endpoint, { token: guestCredential.participant_token, expected: [403] });
      }
      await request('a', `/api/v1/tracks/${fingerprintPath(track)}/liked`, { method: 'PUT', token: guestCredential.participant_token,
        body: { liked: !track.is_liked }, expected: [403] });
      await request('a', '/api/v2/playback/commands', { method: 'POST', token: guestCredential.participant_token,
        body: { command_id: randomUUID(), kind: 'transfer', device_id: 'spoofed-owner-output' }, expected: [403] });
      await guest.getByRole('button', { name: 'Shared music', exact: true }).click();
      await guest.getByRole('button', { name: `Add ${track.title} to queue`, exact: true }).click();
      await until(async () => (await request('a', `${auxPath}/state`, { token: guestCredential.participant_token })).queue
        .some(entry => entry.track.fingerprint === track.fingerprint && entry.participant_id === guestCredential.participant_id),
        'Guest queue append must persist with participant ownership');
      // This browser is a controller; the selected speaker is another device.
      // Open the discovered Aux session explicitly without transferring output.
      await desktop.locator('.sidebar-aux-chip.live').click();
      await desktop.getByRole('region', { name: 'Upcoming queue', exact: true })
        .getByRole('button', { name: `Remove ${track.title}`, exact: true }).waitFor();
      const globalAfterAux = await state('a');
      assert.equal(globalAfterAux.active_device_id, ownerBeforeAux.active_device_id, 'Joining must preserve host output');
      assert.deepEqual(globalAfterAux.context, ownerBeforeAux.context, 'Aux queue must not replace global owner playback context');
      await guest.reload();
      await guest.getByRole('button', { name: 'Leave Aux', exact: true }).waitFor();
      assert.equal(await guest.locator('footer.player').count(), 0, 'Reload must preserve the dedicated guest role');
      assert.equal(await guest.evaluate(() => window.__codecSmokePlayCalls), 0, 'Shared speaker guest must never start a local player');
      result.checks.push('Legacy Aux explicitly requires an update; v2 joins only after the browser gesture and retains guest role on reload');
      result.checks.push('Shared-speaker guest queues through scoped API, cannot inspect owner data or spoof output, and owner sees Aux queue live');
      const other = await connect(await context(), 'b');
      await other.getByRole('button', { name: 'Playlists', exact: true }).click();
      assert.equal(await other.getByText(temporaryPlaylist.name, { exact: true }).count(), 0, 'A playlist must not leak into B');
      assert.deepEqual(durableLibrary(await library('b')), durableLibrary(originalB), 'B library must remain unchanged');
      assert.deepEqual((await state('b'))?.context, playbackBBefore?.context, 'A queue must not leak into B');
      result.checks.push('Server B uses a separate browser/login and retains its independent library and queue');
      for (const [label, page] of [['desktop', desktop], ['mobile', mobile]]) {
        const name = `${browserName}-${label}.png`;
        await page.screenshot({ path: path.join(output, name) }); result.screenshots.push(name);
      }
      assert.deepEqual(result.pageErrors, [], 'Unhandled browser errors');
      result.passed = true;
    } catch (error) {
      result.passed = false; result.failure = redact(error.message); report.failures.push(`${browserName}: ${result.failure}`);
    } finally {
      for (const context of contexts) await context.close().catch(error => cleanupFailures.push(redact(error.message)));
      await browser?.close().catch(error => cleanupFailures.push(redact(error.message)));
      for (const operation of [
        () => aux && request('a', `/api/v2/aux/sessions/${encodeURIComponent(aux.session_id)}`, { method: 'DELETE', expected: [204] }),
        () => temporaryPlaylist && request('a', `/api/v1/playlists/${encodeURIComponent(temporaryPlaylist.id)}`, { method: 'DELETE', expected: [204] }),
        () => request('a', `/api/v1/tracks/${fingerprintPath(track)}/liked`, { method: 'PUT', body: { liked: track.is_liked } }),
        () => restorePlayback(playbackBefore, track)
      ]) {
        try { await operation(); } catch (error) { cleanupFailures.push(redact(error.message)); }
      }
      try {
        assert.deepEqual(durableLibrary(await library('a')), durableLibrary(originalA), 'Restore original local library memberships and likes');
        if (guestCredential) await request('a', `/api/v2/aux/sessions/${encodeURIComponent(aux.session_id)}/state`, { token: guestCredential.participant_token, expected: [401] });
        result.cleanup = 'Test playlist removed, Aux session revoked, original likes/memberships restored; playback left paused';
      } catch (error) { cleanupFailures.push(redact(error.message)); }
      if (cleanupFailures.length) { result.passed = false; result.cleanupFailures = cleanupFailures; report.failures.push(`${browserName}: cleanup failed`); }
    }
  }
} catch (error) { report.failures.push(redact(error.message)); }
finally {
  report.finished_at = new Date().toISOString(); report.passed = report.failures.length === 0;
  await fs.writeFile(path.join(output, 'report.json'), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
}
console.log(JSON.stringify({ passed: report.passed, browsers: report.browsers.map(item => ({ browser: item.browser, passed: item.passed, checks: item.checks.length })),
  failures: report.failures, report: path.join(output, 'report.json') }, null, 2));
if (!report.passed) process.exitCode = 1;
