import { expect, test } from "bun:test";
import { fetchImportJob, setSyncAuthToken, uploadBundle } from "./sync";

const CHUNK = 8 * 1024 * 1024;
const bigBundle = () => new Blob([new Uint8Array(CHUNK + 10)]);

class UploadFixture {
  status = 0;
  responseText = "";
  method = "";
  url = "";
  body: Blob | string | null = null;
  headers = new Map<string, string>();
  aborted = false;
  upload: { onprogress: ((event: { loaded: number; total: number; lengthComputable: boolean }) => void) | null } = { onprogress: null };
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onabort: (() => void) | null = null;
  ontimeout: (() => void) | null = null;
  onprogress: (() => void) | null = null;
  static requests: UploadFixture[] = [];
  static respond: (request: UploadFixture) => void = () => {};
  open(method: string, url: string) { this.method = method; this.url = url; }
  setRequestHeader(key: string, value: string) { this.headers.set(key, value); }
  send(body: Blob | string | null) {
    this.body = body;
    UploadFixture.requests.push(this);
    queueMicrotask(() => UploadFixture.respond(this));
  }
  abort() { this.aborted = true; this.onabort?.(); }
  reply(status: number, body: unknown) {
    this.status = status;
    this.responseText = typeof body === "string" ? body : JSON.stringify(body);
    this.onload?.();
  }
  progress(loaded: number) {
    this.upload.onprogress?.({ loaded, total: this.body instanceof Blob ? this.body.size : 0, lengthComputable: true });
  }
}

async function withUploadFixture(respond: typeof UploadFixture.respond, run: () => Promise<void>) {
  const original = globalThis.XMLHttpRequest;
  UploadFixture.requests = [];
  UploadFixture.respond = respond;
  Object.defineProperty(globalThis, "XMLHttpRequest", { configurable: true, writable: true, value: UploadFixture });
  try { await run(); }
  finally {
    setSyncAuthToken("");
    if (original) globalThis.XMLHttpRequest = original;
    else Reflect.deleteProperty(globalThis, "XMLHttpRequest");
  }
}

async function withTimers(run: (timers: Map<number, { callback: () => void; delay: number }>) => Promise<void>) {
  const originalSet = globalThis.setTimeout;
  const originalClear = globalThis.clearTimeout;
  const timers = new Map<number, { callback: () => void; delay: number }>();
  let id = 0;
  Object.defineProperty(globalThis, "setTimeout", { configurable: true, writable: true, value: (callback: () => void, delay: number) => {
    timers.set(++id, { callback, delay });
    return id;
  } });
  Object.defineProperty(globalThis, "clearTimeout", { configurable: true, writable: true, value: (timer: number) => timers.delete(timer) });
  try { await run(timers); }
  finally { globalThis.setTimeout = originalSet; globalThis.clearTimeout = originalClear; }
}

const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
const uploadStatus = (offset: number, size = CHUNK + 10) => ({ id: "upload_fixture", offset, size, chunk_size: CHUNK });
const job = { id: "import_fixture", state: "running" as const, total: 1, done: 0, added: 0, existing: 0, skipped: 0, playlist_adds: 0, liked: 0 };

test("bundle upload explains proxy size limits without exposing response bodies", async () => {
  await withUploadFixture(request => request.reply(413, "private proxy diagnostics"), async () => {
    await expect(uploadBundle("https://codec.invalid", new Blob(), () => {})).rejects.toThrow("server or proxy upload limit");
    expect(UploadFixture.requests).toHaveLength(1);
  });
});

test("bundle upload requires a real job id before entering processing", async () => {
  for (const body of [{}, { id: "   " }, "<html>proxy diagnostics</html>"]) {
    await withUploadFixture(request => request.reply(202, body), async () => {
      await expect(uploadBundle("https://codec.invalid", new Blob(), () => {})).rejects.toThrow("bad response");
    });
  }
  await withUploadFixture(request => request.reply(202, { id: "import_fixture" }), async () => {
    expect(await uploadBundle("https://codec.invalid", new Blob(), () => {})).toBe("import_fixture");
  });
});

test("stalled uploads time out; repeated progress events without new bytes do not prolong them", async () => {
  await withTimers(async timers => {
    await withUploadFixture(() => {}, async () => {
      const uploading = uploadBundle("https://codec.invalid", new Blob(["abcd"]), () => {});
      const request = UploadFixture.requests[0];
      const initialTimer = [...timers.keys()][0];
      request.progress(2);
      expect(timers.has(initialTimer)).toBe(false);
      const activeTimer = [...timers.keys()][0];
      request.progress(2);
      expect([...timers.keys()]).toEqual([activeTimer]);
      expect(timers.get(activeTimer)?.delay).toBe(30_000);
      timers.get(activeTimer)?.callback();
      await expect(uploading).rejects.toThrow("stopped responding");
      expect(request.aborted).toBe(true);
      expect(timers.size).toBe(0);
    });
  });
});

test("abort settles a stalled upload and a pre-aborted import sends nothing", async () => {
  await withUploadFixture(() => {}, async () => {
    const controller = new AbortController();
    const uploading = uploadBundle("https://codec.invalid", new Blob(), () => {}, { signal: controller.signal });
    controller.abort();
    await expect(uploading).rejects.toMatchObject({ name: "AbortError" });
    expect(UploadFixture.requests[0].aborted).toBe(true);
    await expect(uploadBundle("https://codec.invalid", new Blob(), () => {}, { signal: controller.signal }))
      .rejects.toMatchObject({ name: "AbortError" });
    expect(UploadFixture.requests).toHaveLength(1);
  });
});

test("changing login aborts the old upload and never sends the replacement credentials", async () => {
  await withUploadFixture(() => {}, async () => {
    setSyncAuthToken("first-local-fixture");
    const uploading = uploadBundle("https://codec.invalid", bigBundle(), () => {});
    setSyncAuthToken("second-local-fixture");
    await expect(uploading).rejects.toMatchObject({ name: "AbortError" });
    expect(UploadFixture.requests).toHaveLength(1);
    expect(UploadFixture.requests[0].headers.get("Authorization")).toBe("Bearer first-local-fixture");
    expect(UploadFixture.requests[0].aborted).toBe(true);
  });
});

test("large bundles stream bounded Blob slices and recover a lost chunk response without resending bytes", async () => {
  const chunks: { offset: number; size: number }[] = [];
  const progress: number[] = [];
  let lost = false;
  let confirmed = 0;
  await withUploadFixture(request => {
    if (request.url.endsWith("/uploads")) return request.reply(201, uploadStatus(0));
    if (request.method === "PUT") {
      const offset = Number(new URL(request.url).searchParams.get("offset"));
      expect(request.body).toBeInstanceOf(Blob);
      const size = (request.body as Blob).size;
      chunks.push({ offset, size });
      confirmed = offset + size;
      request.progress(size);
      if (!lost) { lost = true; request.onerror?.(); return; }
      return request.reply(200, uploadStatus(confirmed));
    }
    if (request.method === "GET") return request.reply(200, uploadStatus(confirmed));
    if (request.url.endsWith("/complete")) return request.reply(202, { id: "import_fixture" });
    throw new Error(`Unexpected request ${request.method}`);
  }, async () => {
    expect(await uploadBundle("https://codec.invalid", bigBundle(), fraction => progress.push(fraction))).toBe("import_fixture");
    expect(chunks).toEqual([{ offset: 0, size: CHUNK }, { offset: CHUNK, size: 10 }]);
    expect(progress).toEqual([...progress].sort((a, b) => a - b));
    expect(progress.at(-1)).toBe(1);
    expect(UploadFixture.requests.filter(request => request.method === "GET")).toHaveLength(1);
    expect(UploadFixture.requests.some(request => request.method === "DELETE")).toBe(false);
  });
});

test("lost completion replies recover the same import job through idempotent completion", async () => {
  let completed = false;
  let completeCalls = 0;
  await withUploadFixture(request => {
    if (request.url.endsWith("/uploads")) return request.reply(201, uploadStatus(0));
    if (request.method === "PUT") {
      const offset = Number(new URL(request.url).searchParams.get("offset"));
      return request.reply(200, uploadStatus(offset + (request.body as Blob).size));
    }
    if (request.method === "GET") return request.reply(200, { ...uploadStatus(CHUNK + 10), job_id: "import_fixture" });
    if (request.url.endsWith("/complete")) {
      completeCalls++;
      if (!completed) { completed = true; request.onerror?.(); return; }
      return request.reply(202, { id: "import_fixture" });
    }
    throw new Error(`Unexpected request ${request.method}`);
  }, async () => {
    expect(await uploadBundle("https://codec.invalid", bigBundle(), () => {})).toBe("import_fixture");
    expect(completeCalls).toBe(2);
  });
});

test("failed chunks retry only twice and cancel their incomplete upload", async () => {
  await withUploadFixture(request => {
    if (request.url.endsWith("/uploads")) return request.reply(201, uploadStatus(0));
    if (request.method === "PUT") { request.onerror?.(); return; }
    if (request.method === "GET") return request.reply(200, uploadStatus(0));
    if (request.method === "DELETE") return request.reply(204, "");
    throw new Error(`Unexpected request ${request.method}`);
  }, async () => {
    await expect(uploadBundle("https://codec.invalid", bigBundle(), () => {})).rejects.toThrow("interrupted");
    await flush();
    expect(UploadFixture.requests.filter(request => request.method === "PUT")).toHaveLength(3);
    expect(UploadFixture.requests.filter(request => request.method === "DELETE")).toHaveLength(1);
  });
});

test("auth and size rejection are terminal and are never retried", async () => {
  for (const status of [401, 403, 413]) {
    await withUploadFixture(request => {
      if (request.url.endsWith("/uploads")) return request.reply(201, uploadStatus(0));
      if (request.method === "PUT") return request.reply(status, "private diagnostics");
      if (request.method === "DELETE") return request.reply(204, "");
      throw new Error(`Unexpected request ${request.method}`);
    }, async () => {
      await expect(uploadBundle("https://codec.invalid", bigBundle(), () => {})).rejects.toThrow();
      await flush();
      expect(UploadFixture.requests.filter(request => request.method === "PUT")).toHaveLength(1);
      expect(UploadFixture.requests.some(request => request.method === "GET")).toBe(false);
    });
  }
});

test("older servers use the legacy small archive route but never attempt a huge single upload", async () => {
  for (const status of [404, 405]) {
    await withUploadFixture(request => {
      if (request.url.endsWith("/uploads")) return request.reply(status, "unsupported");
      return request.reply(202, { id: "import_fixture" });
    }, async () => {
      expect(await uploadBundle("https://codec.invalid", bigBundle(), () => {})).toBe("import_fixture");
      expect(UploadFixture.requests[1].url).toEndWith("/bundle");
      const small = new Blob([new Uint8Array(1024)]);
      const huge = new Blob(Array.from({ length: 65 * 1024 }, () => small));
      await expect(uploadBundle("https://codec.invalid", huge, () => {})).rejects.toThrow("Update your Codec server");
      expect(UploadFixture.requests).toHaveLength(3);
    });
  }
});

test("import polling bounds reading the JSON body and aborts stalled reads", async () => {
  await withTimers(async timers => {
    let readSignal: AbortSignal | undefined;
    const fetcher = (async (_url: string, init: RequestInit) => {
      readSignal = init.signal as AbortSignal;
      return { ok: true, status: 200, json: () => new Promise(() => {}) };
    }) as unknown as typeof fetch;
    const reading = fetchImportJob("https://codec.invalid", job.id, fetcher);
    await flush();
    expect([...timers.values()][0].delay).toBe(15_000);
    [...timers.values()][0].callback();
    await expect(reading).rejects.toThrow("taking too long");
    expect(readSignal?.aborted).toBe(true);
    expect(timers.size).toBe(0);
  });
});

test("poll cancellation and login changes discard delayed responses", async () => {
  for (const loginChange of [false, true]) {
    const controller = new AbortController();
    const fetcher = (() => new Promise(() => {})) as unknown as typeof fetch;
    const reading = fetchImportJob("https://codec.invalid", job.id, fetcher, controller.signal);
    if (loginChange) setSyncAuthToken("new-local-fixture");
    else controller.abort();
    await expect(reading).rejects.toMatchObject({ name: "AbortError" });
    setSyncAuthToken("");
  }
});

test("poll responses require the expected job id, state, and finite nonnegative counts", async () => {
  for (const response of [null, {}, { ...job, id: "other_job" }, { ...job, state: "nonsense" }, { ...job, done: -1 }]) {
    const fetcher = (async () => new Response(JSON.stringify(response))) as unknown as typeof fetch;
    await expect(fetchImportJob("https://codec.invalid", job.id, fetcher)).rejects.toThrow("bad response");
  }
  const fetcher = (async () => new Response(JSON.stringify(job))) as unknown as typeof fetch;
  expect(await fetchImportJob("https://codec.invalid", job.id, fetcher)).toEqual(job);
});
