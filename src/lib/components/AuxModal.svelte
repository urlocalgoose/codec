<script lang="ts">
  import QRCode from "qrcode";
  import { Link, Music, X } from "lucide-svelte";
  import { auxQrPalette } from "$lib/aux-session";

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
  let passEl: HTMLDivElement | undefined = $state();
  let qrPaper = $state("#ffffff");

  $effect(() => {
    if (canvas && passEl && auxLink) {
      const styles = getComputedStyle(passEl);
      const palette = auxQrPalette(
        styles.getPropertyValue("--color-bg"),
        styles.getPropertyValue("--color-text")
      );
      qrPaper = palette.light;
      void QRCode.toCanvas(canvas, auxLink, {
        width: 168,
        margin: 1,
        color: { dark: palette.dark, light: palette.light }
      });
    }
  });

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
    class="app-modal aux-modal"
    role="dialog"
    aria-label="Aux session"
    aria-modal="true"
  >
    <header class="modal-header">
      <div>
        <span>Aux</span>
        <h2>You're on the aux</h2>
        <p>Scan from any phone — other Codec servers included.</p>
      </div>
      <button
        class="title-icon-button"
        title="Close"
        aria-label="Close aux session"
        type="button"
        onclick={onClose}
      >
        <X size={18} />
      </button>
    </header>

    <div class="aux-pass" bind:this={passEl}>
      <div class="aux-pass-head">
        <span class="aux-pass-mark" aria-hidden="true">
          <Music size={21} />
        </span>
        <div class="aux-pass-title">
          <strong>Codec Aux</strong>
          <span>Ready to pass</span>
        </div>
        <span class="aux-pass-chip">Live</span>
      </div>
      <div class="aux-pass-body">
        <div class="aux-qr-plate" style={`background: ${qrPaper}`}>
          <canvas bind:this={canvas}></canvas>
        </div>
        <div class="aux-pass-meta">
          <div class="aux-pass-code" aria-label="Aux code">{auxCode}</div>
          <dl class="aux-spec">
            <div><dt>Scan</dt><dd>phone camera</dd></div>
            <div><dt>Link</dt><dd>share or copy</dd></div>
            <div><dt>Queue</dt><dd>shared</dd></div>
          </dl>
          <div class="aux-pass-tape" aria-hidden="true">
            <i class="on"></i><i></i><i></i><i></i>
          </div>
        </div>
      </div>
    </div>

    <footer class="modal-actions">
      <button class="ui-button compact" type="button" onclick={onEnd}>
        End the aux
      </button>
      <button class="ui-button primary compact" type="button" onclick={onCopyLink}>
        <Link size={15} />
        Copy link
      </button>
    </footer>
  </div>
</div>
