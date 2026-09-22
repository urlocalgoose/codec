import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

// Execute the real worker. Only SvelteKit's build-time virtual import is replaced.
const workerSource = readFileSync(new URL("../service-worker.js", import.meta.url), "utf8")
  .replace(/import\s*\{[^}]+\}\s*from\s*["']\$service-worker["'];?/, "");
const origin = "https://codec.test";
const cacheName = "codec-app-test-version";
const bundlePath = "/_app/immutable/entry/app.test.js";

type Listener = (event: {
  request?: Request;
  respondWith: (response: Response | Promise<Response | undefined>) => void;
  waitUntil: (promise: Promise<unknown>) => void;
}) => void;

function harness(options: {
  network?: (request: Request) => Promise<Response>;
  cacheReadError?: boolean;
  cacheWriteError?: boolean;
  cacheOpenError?: boolean;
} = {}) {
  const listeners = new Map<string, Listener>();
  const stores = new Map<string, Map<string, Response>>();
  const fetches: Request[] = [];
  const deleted: string[] = [];
  const key = (request: Request | string) => new URL(typeof request === "string" ? request : request.url, origin).href;
  const store = (name: string) => {
    if (!stores.has(name)) stores.set(name, new Map());
    return stores.get(name)!;
  };
  const read = async (name: string, request: Request | string) => {
    if (options.cacheReadError) throw new Error("Cache storage unavailable");
    return store(name).get(key(request))?.clone();
  };
  const caches = {
    async open(name: string) {
      if (options.cacheOpenError) throw new Error("Cache storage denied");
      return {
        match: (request: Request | string) => read(name, request),
        async put(request: Request | string, response: Response) {
          if (options.cacheWriteError) throw new Error("Cache quota exceeded");
          store(name).set(key(request), response.clone());
        },
        async addAll(_requests: string[]) {},
      };
    },
    async match(request: Request | string, options?: { cacheName?: string }) {
      if (options?.cacheName) return read(options.cacheName, request);
      for (const name of stores.keys()) {
        const response = await read(name, request);
        if (response) return response;
      }
      if (options === undefined && !stores.size) return read(cacheName, request);
      return undefined;
    },
    async keys() { return [...stores.keys()]; },
    async delete(name: string) { deleted.push(name); return stores.delete(name); },
  };
  runInNewContext(workerSource, {
    build: [bundlePath], files: ["/favicon.png", "/manifest.webmanifest"], version: "test-version",
    caches, URL, Request, Response, Headers, console,
    fetch: async (request: Request) => {
      fetches.push(request);
      return options.network ? options.network(request) : new Response("network");
    },
    self: {
      location: new URL(`${origin}/service-worker.js`),
      addEventListener(type: string, listener: Listener) { listeners.set(type, listener); },
      skipWaiting: async () => {}, clients: { claim: async () => {} },
    },
  }, { filename: "service-worker.js" });
  return {
    fetches, deleted,
    seed(name: string, path: string, body: string) { store(name).set(key(path), new Response(body)); },
    async dispatch(type: string, request?: Request) {
      let response: Promise<Response | undefined> | undefined;
      const lifetimes: Promise<unknown>[] = [];
      listeners.get(type)!({
        request,
        respondWith(value) { response = Promise.resolve(value); },
        waitUntil(value) { lifetimes.push(value); },
      });
      const intercepted = response !== undefined;
      const result = await response;
      await Promise.all(lifetimes);
      return { intercepted, response: result };
    },
  };
}

const offline = async () => { throw new TypeError("Load failed"); };
function request(path: string, init?: RequestInit & { navigate?: boolean }) {
  const result = new Request(new URL(path, origin), init);
  if (init?.navigate) Object.defineProperty(result, "mode", { value: "navigate" });
  return result;
}

for (const path of ["/health", "/api/v1/library", "/api/v2/playback/events", "/music/example.mp3", "/unknown-resource", "https://other.test/favicon.png"]) {
  test(`service worker leaves ${path} to the browser's network handling`, async () => {
    const worker = harness({ network: offline });
    expect((await worker.dispatch("fetch", request(path))).intercepted).toBe(false);
    expect(worker.fetches).toHaveLength(0);
  });
}

test("service worker does not intercept Range requests, even for a shell asset", async () => {
  const worker = harness({ network: offline });
  expect((await worker.dispatch("fetch", request("/favicon.png", { headers: { Range: "bytes=0-15" } }))).intercepted).toBe(false);
});

test("service worker leaves mutations to the network", async () => {
  const worker = harness();
  expect((await worker.dispatch("fetch", request("/", { method: "POST" }))).intercepted).toBe(false);
});

test("an unavailable cache does not break a healthy asset response", async () => {
  const worker = harness({ cacheReadError: true });
  const { response } = await worker.dispatch("fetch", request(bundlePath));
  expect(await response?.text()).toBe("network");
  expect(worker.fetches).toHaveLength(1);
});

for (const path of ["/", bundlePath]) {
  test(`denied cache access does not block a healthy response for ${path}`, async () => {
    const worker = harness({ cacheOpenError: true });
    const { response } = await worker.dispatch("fetch", request(path, { navigate: path === "/" }));
    expect(await response?.text()).toBe("network");
  });

  test(`cache quota failures do not reject the response or event lifetime for ${path}`, async () => {
    const worker = harness({ cacheWriteError: true });
    const { response } = await worker.dispatch("fetch", request(path, { navigate: path === "/" }));
    expect(await response?.text()).toBe("network");
  });
}

test("offline navigation uses the active build's shell, not another feature's cache", async () => {
  const worker = harness({ network: offline });
  worker.seed("codec-audio-downloads", "/", "not the app shell");
  worker.seed("codec-app-old-version", "/", "outdated shell");
  worker.seed(cacheName, "/", "current app shell");
  const { response } = await worker.dispatch("fetch", request("/?aux=ABCD", { navigate: true }));
  expect(await response?.text()).toBe("current app shell");
});

for (const cacheReadError of [false, true]) {
  test(`offline navigation without a usable shell returns a Response (cache error: ${cacheReadError})`, async () => {
    const worker = harness({ network: offline, cacheReadError });
    const { response } = await worker.dispatch("fetch", request("/", { navigate: true }));
    expect(response).toBeInstanceOf(Response);
    expect(response?.status).toBe(503);
    expect(response?.headers.get("content-type")).toContain("text/html");
  });
}

test("an uncached asset while offline returns a failed HTTP response, never a rejected respondWith promise", async () => {
  const worker = harness({ network: offline });
  const { response } = await worker.dispatch("fetch", request(bundlePath));
  expect(response).toBeInstanceOf(Response);
  expect(response?.status).toBe(503);
  expect(response?.headers.get("cache-control")).toContain("no-store");
});

test("navigation survives a gateway outage using the cached shell", async () => {
  const worker = harness({ network: async () => new Response("Bad Gateway", { status: 502 }) });
  worker.seed(cacheName, "/", "current app shell");
  const { response } = await worker.dispatch("fetch", request("/", { navigate: true }));
  expect(await response?.text()).toBe("current app shell");
});

for (const status of [401, 403]) {
  test(`navigation retains an HTTP ${status} response instead of hiding it with cached content`, async () => {
    const worker = harness({ network: async () => new Response("Access denied", { status }) });
    worker.seed(cacheName, "/", "current app shell");
    const { response } = await worker.dispatch("fetch", request("/", { navigate: true }));
    expect(response?.status).toBe(status);
    expect(await response?.text()).toBe("Access denied");
  });
}

test("activation removes obsolete shell caches while keeping audio downloads", async () => {
  const worker = harness();
  worker.seed("codec-app-old-version", "/", "old");
  worker.seed(cacheName, "/", "current");
  worker.seed("codec-audio-downloads", "/song", "audio");
  await worker.dispatch("activate");
  expect(worker.deleted).toEqual(["codec-app-old-version"]);
});
