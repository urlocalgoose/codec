# WebKit connection / service-worker recovery

September 21, 2026: reproduced the exact reported `FetchEvent.respondWith received an error: TypeError: Load failed` in real WebKit by disconnecting `/health` while the earlier worker controlled the page. The connection form checks `/health` first. The old worker intercepted all same-origin GETs outside `/api/` and allowed this fetch rejection to escape. Its navigation fallback could also resolve `undefined` after cache eviction, and cache read errors could block healthy network requests.

The worker now handles only navigation and app-shell assets. Health/API requests, Range requests and unrelated URLs bypass it. Cache failures do not prevent network access; offline navigation always returns a cached page or a valid 503 page. Gateway failures can use the saved shell, while HTTP 401/403 remain visible. Cache writes are caught and attached to the event lifetime. Activation cleans only older shell caches and preserves audio downloads.

API transport failures now have useful connection copy. Abort errors retain their identity. A raw engine error does not establish why a network request failed; diagnose transport, HTTP status, and credentials separately.

Validation:

- 142 frontend tests pass, including 21 worker failure-path tests.
- Zero Svelte/TypeScript diagnostics; production build passes.
- `scripts/service-worker-regression.mjs` passes 11 scenarios in WebKit with real active workers, including the actual connection form.
- Existing offline-download and audio-continuity browser regressions pass.

Reproduce with a production build and installed Playwright WebKit:

```sh
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/service-worker-regression.mjs build /tmp/codec-service-worker-report.json
```

Fixtures use isolated local responses and generated failure conditions, never live credentials.
