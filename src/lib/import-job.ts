import type { ImportJobStatus } from "./sync";

export type ImportPhase = "idle" | "preparing" | "uploading" | "processing" | "done" | "failed" | "cancelled";

/** One bounded status read at a time. A slow server must not accumulate polls. */
export function monitorImportJob(options: {
  read: (signal: AbortSignal) => Promise<ImportJobStatus | null>;
  onStatus: (status: ImportJobStatus) => void;
  onMissing: () => void;
  onError: (error: unknown) => void;
  intervalMs?: number;
}) {
  const interval = options.intervalMs ?? 1_000;
  let stopped = false;
  let generation = 0;
  let failures = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let controller: AbortController | undefined;

  async function poll() {
    if (stopped) return;
    const current = ++generation;
    controller = new AbortController();
    try {
      const status = await options.read(controller.signal);
      if (stopped || current !== generation) return;
      failures = 0;
      if (!status) {
        stop();
        options.onMissing();
      } else {
        if (status.state !== "running") stop();
        options.onStatus(status);
      }
    } catch (error) {
      if (stopped || current !== generation) return;
      failures++;
      options.onError(error);
    } finally {
      if (!stopped && current === generation) {
        controller = undefined;
        timer = setTimeout(poll, Math.min(15_000, interval * 2 ** Math.min(failures, 4)));
      }
    }
  }

  function stop() {
    stopped = true;
    generation++;
    clearTimeout(timer);
    controller?.abort();
    controller = undefined;
  }

  function retry() {
    if (stopped) return;
    generation++;
    clearTimeout(timer);
    controller?.abort();
    void poll();
  }

  void poll();
  return { stop, retry };
}

/** Job IDs belong to one server. Never persist credentials with import state. */
export function importJobStorageKey(server: string): string {
  return `codec.importJob:${encodeURIComponent(server.trim().replace(/\/+$/, ""))}`;
}
