/// <reference types="@sveltejs/kit" />
// Built by SvelteKit so `version` changes every build - that's what makes
// installed PWAs pick up new deploys. The old static service worker never
// changed bytes, so devices stayed pinned to their first cached build.
import { build, files, version } from "$service-worker";

const CACHE_NAME = `codec-app-${version}`;
const PRECACHE = [...build, ...files, "/"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") {
    return;
  }
  const url = new URL(request.url);
  // The API is never intercepted: library, playback SSE, and media streams
  // must always hit the server live.
  if (url.origin !== self.location.origin || url.pathname.startsWith("/api/")) {
    return;
  }

  // The shell is network-first so deploys land immediately; the cached copy
  // is only the offline fallback.
  if (request.mode === "navigate" || url.pathname === "/") {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.ok) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put("/", copy));
          }
          return response;
        })
        .catch(() => caches.match("/"))
    );
    return;
  }

  // Hashed build assets and static files: cache-first, they never change
  // under the same name.
  event.respondWith(
    caches.match(request).then(
      (cached) =>
        cached ??
        fetch(request).then((response) => {
          if (response.ok && url.pathname.startsWith("/_app/immutable/")) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          }
          return response;
        })
    )
  );
});
