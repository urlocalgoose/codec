import { expect, test } from "bun:test";
import { importJobStorageKey, monitorImportJob } from "./import-job";
import type { ImportJobStatus } from "./sync";

const pause = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
const status = (state: "running" | "done" = "running"): ImportJobStatus => ({
  id: "import-test", state, total: 2, done: state === "done" ? 2 : 1,
  added: 1, existing: 0, skipped: 0, playlist_adds: 0, liked: 0
});

test("slow import status is serialized and stopping suppresses late responses", async () => {
  let calls = 0, updates = 0;
  let release!: (value: ImportJobStatus) => void;
  let signal!: AbortSignal;
  const monitor = monitorImportJob({
    read: current => { calls++; signal = current; return new Promise(resolve => { release = resolve; }); },
    onStatus: () => { updates++; }, onMissing: () => {}, onError: () => {}, intervalMs: 5
  });
  await pause(35);
  expect(calls).toBe(1);
  monitor.stop();
  expect(signal.aborted).toBe(true);
  release(status());
  await pause(20);
  expect(updates).toBe(0);
  expect(calls).toBe(1);
});

test("an import read failure is visible and a manual retry completes without further polls", async () => {
  let calls = 0, errors = 0, updates = 0;
  const monitor = monitorImportJob({
    read: async () => { if (++calls === 1) throw new Error("Disconnected"); return status("done"); },
    onStatus: () => { updates++; }, onMissing: () => {}, onError: () => { errors++; }, intervalMs: 1_000
  });
  await pause(5);
  expect(errors).toBe(1);
  monitor.retry();
  await pause(10);
  expect(calls).toBe(2);
  expect(updates).toBe(1);
  monitor.retry();
  await pause(10);
  expect(calls).toBe(2);
  monitor.stop();
});

test("a missing import ends polling instead of retrying a lost job forever", async () => {
  let calls = 0, missing = 0;
  const monitor = monitorImportJob({ read: async () => { calls++; return null; },
    onStatus: () => {}, onMissing: () => { missing++; }, onError: () => {}, intervalMs: 5 });
  await pause(25);
  expect(missing).toBe(1);
  expect(calls).toBe(1);
  monitor.stop();
});

test("saved import jobs are scoped to a normalized server without credentials", () => {
  expect(importJobStorageKey("https://a.invalid/")).toBe(importJobStorageKey("https://a.invalid"));
  expect(importJobStorageKey("https://a.invalid")).not.toBe(importJobStorageKey("https://b.invalid"));
});
