/// <reference types="@sveltejs/kit" />
import { build, files, version } from "$service-worker";

const CACHE_NAME = `codec-app-${version}`;
const PRECACHE = [...new Set([...build, ...files, "/"])];
const SHELL_FILES = new Set([...build, ...files].map((path) => new URL(path, self.location.origin).pathname));

self.addEventListener("install", (event) => {
  // If a new shell cannot be fully saved, keep the previous working worker.
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(PRECACHE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key.startsWith("codec-app-") && key !== CACHE_NAME).map((key) => caches.delete(key))))
      .catch(() => undefined)
      .then(() => self.clients.claim())
  );
});

async function cachedResponse(key) {
  try { return await (await caches.open(CACHE_NAME)).match(key); }
  catch { return undefined; } // Private mode / storage failure must not break online requests.
}

function saveResponse(event, key, response) {
  const copy = response.clone();
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.put(key, copy)).catch(() => undefined));
}

function unavailable(navigation = false) {
  return new Response(navigation
    ? '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Codec</title><style>body{margin:0;min-height:100dvh;display:grid;place-items:center;background:#100f0c;color:#f5efe2;font:17px -apple-system,system-ui,sans-serif}main{max-width:340px;padding:32px}h1{font-size:24px}p{color:#bbb3a2;line-height:1.5}a{display:inline-block;padding:14px 22px;border-radius:14px;background:#f47b3f;color:#130f0a;text-decoration:none;font-weight:600}</style><main><h1>Codec is offline</h1><p>This browser does not have a saved copy of the app yet. Reconnect, then try again.</p><a href="/">Try again</a></main></html>'
    : "Codec could not load this app file. Reconnect and reload.", {
    status: 503,
    headers: { "Content-Type": navigation ? "text/html; charset=utf-8" : "text/plain; charset=utf-8", "Cache-Control": "no-store" }
  });
}

async function navigationResponse(event) {
  try {
    const response = await fetch(event.request);
    if (response.ok) saveResponse(event, "/", response);
    if (response.status < 500) return response;
    return (await cachedResponse("/")) ?? response;
  } catch {
    // respondWith must always receive a Response, even after cache eviction.
    return (await cachedResponse("/")) ?? unavailable(true);
  }
}

async function assetResponse(event) {
  const cached = await cachedResponse(event.request);
  if (cached) return cached;
  try {
    const response = await fetch(event.request);
    if (response.ok && response.status !== 206) saveResponse(event, event.request, response);
    return response;
  } catch { return unavailable(); }
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET" || request.headers.has("range")) return;
  const url = new URL(request.url);
  // Health, API, audio and arbitrary application requests use the network
  // directly. This worker owns only the document and static app-shell files.
  if (url.origin !== self.location.origin || url.pathname === "/health" || url.pathname === "/api" || url.pathname.startsWith("/api/")) return;
  if (request.mode === "navigate") {
    event.respondWith(navigationResponse(event));
  } else if (SHELL_FILES.has(url.pathname) || url.pathname.startsWith("/_app/immutable/")) {
    event.respondWith(assetResponse(event));
  }
});
