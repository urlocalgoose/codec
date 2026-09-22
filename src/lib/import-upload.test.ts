import { expect, test } from "bun:test";
import { uploadBundle } from "./sync";

async function withUploadResponse(status: number, body: string, run: () => Promise<void>) {
  const original = globalThis.XMLHttpRequest;
  class UploadFixture {
    status = status;
    responseText = body;
    upload = { onprogress: null };
    onload?: () => void;
    open() {}
    setRequestHeader() {}
    send() { queueMicrotask(() => this.onload?.()); }
  }
  Object.defineProperty(globalThis, "XMLHttpRequest", { configurable: true, writable: true, value: UploadFixture });
  try { await run(); }
  finally {
    if (original) globalThis.XMLHttpRequest = original;
    else Reflect.deleteProperty(globalThis, "XMLHttpRequest");
  }
}

test("bundle upload explains proxy size limits without exposing response bodies", async () => {
  await withUploadResponse(413, "private proxy diagnostics", async () => {
    await expect(uploadBundle("https://codec.invalid", new Blob(), () => {})).rejects.toThrow("server or proxy upload limit");
  });
});

test("bundle upload requires a real job id before entering processing", async () => {
  await withUploadResponse(202, "{}", async () => {
    await expect(uploadBundle("https://codec.invalid", new Blob(), () => {})).rejects.toThrow("bad response");
  });
  await withUploadResponse(202, '{"id":"import_fixture"}', async () => {
    expect(await uploadBundle("https://codec.invalid", new Blob(), () => {})).toBe("import_fixture");
  });
});
