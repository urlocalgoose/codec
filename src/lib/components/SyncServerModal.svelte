<script lang="ts">
  import { KeyRound, Server, X } from "lucide-svelte";

  let {
    syncServerUrl,
    syncServerDraft = $bindable(),
    syncTokenDraft = $bindable(),
    onClose,
    onDisconnect,
    onApply
  }: {
    syncServerUrl: string;
    syncServerDraft: string;
    syncTokenDraft: string;
    onClose: () => void;
    onDisconnect: () => void;
    onApply: () => void;
  } = $props();

  function handleBackdropClick(event: MouseEvent) {
    if (event.target === event.currentTarget) {
      onClose();
    }
  }
</script>

<div
  class="modal-backdrop"
  role="presentation"
  onclick={handleBackdropClick}
>
  <div
    class="app-modal sync-server-modal"
    role="dialog"
    aria-label="Sync server"
    aria-modal="true"
  >
    <header class="modal-header">
      <div>
        <span>Sync</span>
        <h2>Sync Server</h2>
        <p>{syncServerUrl || "Not connected"}</p>
      </div>
      <button
        class="title-icon-button"
        title="Close"
        aria-label="Close sync server"
        type="button"
        onclick={onClose}
      >
        <X size={18} />
      </button>
    </header>

    <form
      class="sync-server-form"
      onsubmit={(event) => {
        event.preventDefault();
        onApply();
      }}
    >
      <label class="sync-url-field modal-field">
        <Server size={17} />
        <input
          bind:value={syncServerDraft}
          placeholder="http://192.168.1.20:8787"
          type="url"
        />
      </label>
      <label class="sync-url-field modal-field">
        <KeyRound size={17} />
        <input
          bind:value={syncTokenDraft}
          placeholder="Auth token (optional)"
          type="password"
          autocomplete="off"
        />
      </label>
      <p class="sync-server-help">
        On phone, use the network address printed by the sync server, not localhost.
        The token matches the server's LOUD_AUTH_TOKEN.
      </p>

      <footer class="modal-actions">
        <button class="ui-button compact" type="button" onclick={onDisconnect}>
          Disconnect
        </button>
        <button class="ui-button compact" type="button" onclick={onClose}>
          Cancel
        </button>
        <button class="ui-button primary compact" type="submit">
          Connect
        </button>
      </footer>
    </form>
  </div>
</div>
