const SYNC_READ_TIMEOUT_MS = 8_000;

/** Bound the whole read, including its response body. A suspended mobile
 * connection must not block every later playback refresh indefinitely. */
export async function withSyncReadTimeout<T>(
  read: (signal: AbortSignal) => Promise<T>,
  signal?: AbortSignal,
  timeoutMs = SYNC_READ_TIMEOUT_MS
): Promise<T> {
  const controller = new AbortController();
  let timedOut = false;
  const cancel = () => controller.abort(signal?.reason);
  if (signal?.aborted) cancel();
  else signal?.addEventListener("abort", cancel, { once: true });
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort(new DOMException("Sync read timed out", "TimeoutError"));
  }, timeoutMs);
  try {
    return await read(controller.signal);
  } catch (error) {
    if (timedOut) throw new Error("Your Codec server is taking too long to respond. Try again.");
    throw error;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", cancel);
  }
}
