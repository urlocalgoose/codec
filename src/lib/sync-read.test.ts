import { expect, test } from "bun:test";
import { withSyncReadTimeout } from "./sync-read";

const waitForAbort = (signal: AbortSignal) => new Promise<never>((_, reject) => {
  if (signal.aborted) reject(signal.reason);
  else signal.addEventListener("abort", () => reject(signal.reason), {once:true});
});

test("a stalled sync response is aborted within its deadline", async () => {
  let signal: AbortSignal | undefined;
  await expect(withSyncReadTimeout(next => { signal=next; return waitForAbort(next); },undefined,15))
    .rejects.toThrow("Your Codec server is taking too long");
  expect(signal?.aborted).toBe(true);
});

test("the deadline includes reading the response body", async () => {
  await expect(withSyncReadTimeout(async signal => {
    await Promise.resolve(); // Headers arrived; JSON body is still stalled.
    return waitForAbort(signal);
  },undefined,15)).rejects.toThrow("Your Codec server is taking too long");
});

test("superseding a read keeps cancellation distinct from server failure", async () => {
  const controller = new AbortController();
  const reading = withSyncReadTimeout(waitForAbort,controller.signal,1000);
  controller.abort();
  await expect(reading).rejects.toMatchObject({name:"AbortError"});
});

test("successful reads clear their deadline without late cancellation", async () => {
  let signal: AbortSignal | undefined;
  const value=await withSyncReadTimeout(async next=>{signal=next;return 42;},undefined,10);
  await new Promise(resolve=>setTimeout(resolve,20));
  expect(value).toBe(42);
  expect(signal?.aborted).toBe(false);
});
