<script lang="ts">
  import QRCode from "qrcode";
  import { Link, X } from "lucide-svelte";

  let {
    auxCode,
    auxLink,
    onCopyLink,
    onEnd,
    onClose
  }: {
    auxCode: string;
    auxLink: string;
    onCopyLink: () => void;
    onEnd: () => void;
    onClose: () => void;
  } = $props();

  let canvas: HTMLCanvasElement | undefined = $state();

  $effect(() => {
    if (canvas && auxLink) {
      void QRCode.toCanvas(canvas, auxLink, {
        width: 260,
        margin: 2,
        color: { dark: "#000000", light: "#ffffff" }
      });
    }
  });

  function handleBackdropClick(event: MouseEvent) {
    if (event.target === event.currentTarget) {
      onClose();
    }
  }
</script>

<div class="modal-backdrop" role="presentation" onclick={handleBackdropClick}>
  <div class="modal aux-modal" role="dialog" aria-label="Aux session">
    <header>
      <h2>You're on the aux</h2>
      <button class="ui-button compact" type="button" aria-label="Close" onclick={onClose}>
        <X size={16} />
      </button>
    </header>

    <p class="aux-modal-hint">
      Scan to join from any phone — friends on their own Codec servers included.
    </p>

    <div class="aux-qr-wrap">
      <canvas bind:this={canvas}></canvas>
    </div>

    <div class="aux-modal-code" aria-label="Aux code">{auxCode}</div>

    <div class="aux-modal-actions">
      <button class="ui-button compact" type="button" onclick={onCopyLink}>
        <Link size={15} />
        Copy link
      </button>
      <button class="ui-button compact danger" type="button" onclick={onEnd}>
        End the aux
      </button>
    </div>
  </div>
</div>
