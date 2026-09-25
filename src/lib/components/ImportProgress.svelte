<script lang="ts">
  import type { ImportJobStatus } from "$lib/sync";
  let { phase, fraction, job, message, connectionError = "", onCancel, onRetry, onDismiss }: {
    phase: "idle" | "preparing" | "uploading" | "processing" | "done" | "failed" | "cancelled";
    fraction: number;
    job: ImportJobStatus | null;
    message: string;
    connectionError?: string;
    onCancel: () => void;
    onRetry: () => void;
    onDismiss: () => void;
  } = $props();
  const sending = $derived(phase === "preparing" || phase === "uploading");
  const busy = $derived(sending || phase === "processing");
  const progress = $derived(Math.max(0, Math.min(100, sending ? fraction * 100 : job?.total ? job.done / job.total * 100 : 0)));
</script>

{#if phase !== "idle"}
  <section class="import-banner" class:done={phase === "done"} class:failed={phase === "failed"} aria-label="Import progress" aria-live="polite">
    <div class="import-banner-copy">
      {#if sending}
        <strong>{phase === "preparing" ? "Preparing bundle" : "Uploading bundle"} · {Math.round(progress)}%</strong>
        <span>{phase === "preparing" ? "Collecting audio, playlists, and covers…" : fraction >= 1 ? "Waiting for the server to accept the upload…" : "Keep this tab open until the upload finishes."}</span>
      {:else if phase === "processing"}
        <strong>{connectionError ? "Checking connection…" : `Importing${job?.total ? ` ${job.done}/${job.total}` : ""}`}</strong>
        <span>{connectionError ? "Progress is temporarily unavailable. Retrying automatically; your server may still be importing." : job?.current || "Checking bundle…"}</span>
      {:else}
        <strong>{phase === "done" ? "Import finished" : phase === "cancelled" ? "Import cancelled" : "Import failed"}</strong>
        <span>{message}</span>
      {/if}
    </div>
    {#if busy}
      <div class="import-banner-bar" role="progressbar" aria-label={sending ? "Bundle upload" : "Tracks imported"} aria-valuemin="0" aria-valuemax="100" aria-valuenow={Math.round(progress)}>
        <i style={`width: ${progress}%`}></i>
      </div>
    {/if}
    {#if sending}<button class="ui-button compact" type="button" onclick={onCancel}>Cancel upload</button>
    {:else if connectionError && phase === "processing"}<button class="ui-button compact" type="button" onclick={onRetry}>Check again</button>
    {:else if !busy}<button class="ui-button compact" type="button" onclick={onDismiss}>Dismiss</button>{/if}
  </section>
{/if}
