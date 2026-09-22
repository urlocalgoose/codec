import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// Runs the actual compiled worker in WebKit, with isolated fixture responses.
// Usage: PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/service-worker-regression.mjs [build] [report.json] [--baseline]
const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const { webkit } = await import(moduleName.startsWith('/') ? pathToFileURL(moduleName).href : moduleName);
const build = path.resolve(process.argv[2] ?? 'build');
const output = process.argv[3] ?? '/tmp/codec-service-worker-regression.json';
const baseline = process.argv.includes('--baseline');
const worker = await fs.readFile(path.join(build, 'service-worker.js'), 'utf8');
// Observe whether the real production handler calls respondWith. Cache failure
// injection models disabled/evicted browser storage without replacing fetch.
const instrumentation = `
const originalRespondWith = FetchEvent.prototype.respondWith;
FetchEvent.prototype.respondWith = function(value) {
  self.clients.matchAll().then(clients => clients.forEach(client => client.postMessage({handled: new URL(this.request.url).pathname, range: this.request.headers.get('Range')})));
  return originalRespondWith.call(this, value);
};
let failCache = false;
for (const method of ['open', 'match']) {
  const original = CacheStorage.prototype[method];
  CacheStorage.prototype[method] = function(...args) {
    return failCache ? Promise.reject(new Error('Fixture cache unavailable')) : original.apply(this, args);
  };
}
self.addEventListener('message', event => {
  if (event.data?.fixtureCacheFailure !== undefined) {
    failCache = event.data.fixtureCacheFailure;
    event.ports[0].postMessage('ok');
  }
});
`;
const shell = '<!doctype html><html><body><main id="shell">Codec isolated shell fixture</main></body></html>';
let disconnected = false;
let serveApplication = false;
let healthDisconnected = false;
const requests = [];
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  requests.push({ pathname: url.pathname, disconnected, range: req.headers.range ?? null });
  if (disconnected || (healthDisconnected && url.pathname === '/health')) return req.socket.destroy();
  try {
    if (url.pathname === '/service-worker.js') {
      res.writeHead(200, { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-store' });
      return res.end(instrumentation + worker);
    }
    if ((url.pathname === '/' && !serveApplication) || url.pathname === '/__sw-test') {
      res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
      return res.end(shell);
    }
    if (url.pathname === '/health' || url.pathname.startsWith('/api/')) {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      return res.end(JSON.stringify({ ok: true, path: url.pathname }));
    }
    const file = path.resolve(build, '.' + (url.pathname === '/' ? '/index.html' : decodeURIComponent(url.pathname)));
    if (!file.startsWith(build + path.sep)) return res.writeHead(403).end();
    const data = await fs.readFile(file);
    res.writeHead(200, { 'Content-Type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.webmanifest': 'application/manifest+json' })[path.extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  } catch { res.writeHead(404).end('Fixture missing'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await webkit.launch({ headless: true });
const context = await browser.newContext({ serviceWorkers: 'allow' });
const page = await context.newPage();
const errors = [];
page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
page.on('pageerror', error => errors.push(error.message));
const report = { build, baseline, browser: 'WebKit', phases: [], errors, requests };
await context.addInitScript(() => {
  window.__handled = [];
  navigator.serviceWorker.addEventListener('message', event => { if (event.data?.handled) window.__handled.push(event.data); });
});
async function fetchProbe(name, url, init) {
  await page.evaluate(() => { window.__handled = []; });
  const result = await page.evaluate(async ({ url, init }) => {
    try {
      const response = await fetch(url, init);
      await response.arrayBuffer();
      return { status: response.status, contentType: response.headers.get('Content-Type') };
    } catch (error) { return { error: error.message }; }
  }, { url, init });
  await page.waitForTimeout(80);
  const phase = { name, ...result, handled: await page.evaluate(() => window.__handled) };
  report.phases.push(phase);
  return phase;
}
async function cacheFailure(enabled) {
  await page.evaluate(enabled => new Promise(resolve => {
    const channel = new MessageChannel();
    channel.port1.onmessage = resolve;
    navigator.serviceWorker.controller.postMessage({ fixtureCacheFailure: enabled }, [channel.port2]);
  }), enabled);
}
try {
  await page.goto(origin + '/__sw-test');
  await page.evaluate(async () => {
    await navigator.serviceWorker.register('/service-worker.js');
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true }));
  });
  const health = await fetchProbe('online health bypass', '/health');
  const api = await fetchProbe('online API bypass', '/api/v1/library');
  const range = await fetchProbe('range request bypass', '/favicon.png', { headers: { Range: 'bytes=0-19' } });
  const unknown = await fetchProbe('unknown URL bypass', '/not-a-shell-file');
  disconnected = true;
  const failedHealth = await fetchProbe('disconnected health remains a direct network error', '/health');
  const cached = await fetchProbe('offline precached asset', '/favicon.png');
  const offlineNavigation = await page.goto(origin + '/?offline-shell');
  report.phases.push({ name: 'offline shell navigation', status: offlineNavigation.status(), shell: await page.locator('#shell').count() });
  disconnected = false;
  await cacheFailure(true);
  const unavailable = await fetchProbe('online asset when cache storage is unavailable', '/favicon.png');
  await cacheFailure(false);
  await page.evaluate(async () => {
    for (const key of await caches.keys()) if (key.startsWith('codec-app-')) await caches.delete(key);
  });
  disconnected = true;
  const evictedAsset = await fetchProbe('offline asset after cache eviction', '/favicon.png');
  try {
    const response = await page.goto(origin + '/?evicted-shell');
    report.phases.push({ name: 'offline navigation after cache eviction', status: response.status() });
  } catch (error) { report.phases.push({ name: 'offline navigation after cache eviction', error: error.message }); }
  if (!baseline) {
    for (const phase of [health, api, range, unknown, failedHealth]) assert.equal(phase.handled.length, 0, `${phase.name} must not be intercepted`);
    assert.equal(health.status, 200);
    assert(failedHealth.error, 'Disconnected health must remain a network failure, not an HTML fallback');
    assert.equal(cached.status, 200);
    assert.equal(report.phases.find(p => p.name === 'offline shell navigation').shell, 1);
    assert.equal(unavailable.status, 200, 'Cache failure must not prevent a successful network response');
    assert.equal(evictedAsset.status, 503, 'Offline evicted assets must produce a real response');
    assert.equal(report.phases.at(-1).status, 503, 'Offline evicted navigation must produce a real response');
    assert(!errors.some(error => /respondWith|Fixture cache unavailable/.test(error)), 'No rejected respondWith/cache promises');
    disconnected = false;
    serveApplication = true;
    healthDisconnected = true;
    await page.goto(origin + '/?actual-connect-fixture');
    await page.getByRole('textbox', { name: 'Server address', exact: true }).fill(origin);
    await page.getByLabel('Auth token', { exact: true }).fill('isolated-fixture-token');
    await page.getByRole('button', { name: 'Connect', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('[role="alert"]')?.textContent?.includes('Could not reach your Codec server.'));
    const message = await page.getByRole('alert').innerText();
    assert(!message.includes('FetchEvent') && !message.includes('TypeError'), 'The connect form must show an actionable connection message');
    report.phases.push({ name: 'actual connect screen with disconnected health', message });
  }
  console.log(JSON.stringify({ phases: report.phases, errors }, null, 2));
} finally {
  await fs.writeFile(output, JSON.stringify(report, null, 2));
  await browser.close();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
