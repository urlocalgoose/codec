<script lang="ts">
  import { onMount, type Snippet } from "svelte";
  import { cubicOut } from "svelte/easing";
  import type { TransitionConfig } from "svelte/transition";

  let { title, onClose, children, wide = false, full = false, compact = false, presentation = "standard", leading, trailing, background }: {
    title: string;
    onClose: () => void;
    children: Snippet;
    wide?: boolean;
    full?: boolean;
    compact?: boolean;
    presentation?: "standard" | "player" | "queue";
    leading?: Snippet;
    trailing?: Snippet;
    background?: Snippet;
  } = $props();
  let dialog: HTMLDialogElement;
  let dragStart = 0;
  let dragStartX = 0;
  let dragLastY = 0;
  let dragLastTime = 0;
  let dragVelocity = 0;
  let dragIdentifier: number | null = null;
  let dragSource: "touch" | "pointer" | null = null;
  let dragTarget: HTMLElement | null = null;
  let dragOffset = $state(0);
  let dragging = $state(false);
  let presented = $state(false);
  let leaving = $state(false);
  let suppressGrabberClick = false;
  let dragged = false;

  function sheetEnter(node: HTMLDialogElement): TransitionConfig {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return { duration: 0 };
    const distance = Math.min(240, node.getBoundingClientRect().height * .35);
    return {
      duration: 320,
      easing: cubicOut,
      css: (t, u) => `transform: translate3d(0, ${distance * u}px, 0); opacity: ${t}`,
    };
  }

  function sheetExit(node: HTMLDialogElement): TransitionConfig {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return { duration: 0 };
    // Continue from an interrupted entrance or the user's dragged position.
    const style = getComputedStyle(node);
    const offset = style.transform === "none" ? 0 : new DOMMatrixReadOnly(style.transform).m42;
    const opacity = Number(style.opacity);
    return {
      duration: 180,
      easing: cubicOut,
      css: (t, u) => `transform: translate3d(0, ${offset + 36 * u}px, 0); opacity: ${opacity * t}`,
    };
  }

  onMount(() => {
    const trigger = document.activeElement as HTMLElement | null;
    dialog.showModal();
    // An explicit non-passive listener lets a downward pull take over only at
    // the top. Upward and already-scrolled gestures remain native scrolling.
    dialog.addEventListener("touchstart", touchStart, { passive: true });
    dialog.addEventListener("touchmove", touchMove, { passive: false });
    dialog.addEventListener("touchend", touchEnd);
    dialog.addEventListener("touchcancel", touchCancel);
    dialog.addEventListener("pointerdown", pointerStart);
    dialog.addEventListener("pointermove", pointerMove);
    dialog.addEventListener("pointerup", pointerEnd);
    dialog.addEventListener("pointercancel", pointerCancel);
    dialog.addEventListener("click", suppressDragClick, true);
    let frame = requestAnimationFrame(() => {
      frame = requestAnimationFrame(() => { presented = true; });
    });
    return () => {
      cancelAnimationFrame(frame);
      dialog.removeEventListener("touchstart", touchStart);
      dialog.removeEventListener("touchmove", touchMove);
      dialog.removeEventListener("touchend", touchEnd);
      dialog.removeEventListener("touchcancel", touchCancel);
      dialog.removeEventListener("pointerdown", pointerStart);
      dialog.removeEventListener("pointermove", pointerMove);
      dialog.removeEventListener("pointerup", pointerEnd);
      dialog.removeEventListener("pointercancel", pointerCancel);
      dialog.removeEventListener("click", suppressDragClick, true);
      // Svelte retains the modal until its outro ends, including its focus trap.
      dialog.close();
      if (trigger?.isConnected) trigger.focus({ preventScroll: true });
    };
  });

  function canStartDrag(target: EventTarget | null): target is HTMLElement {
    if (!(target instanceof HTMLElement) || leaving || target.closest("dialog") !== dialog) return false;
    if (target.closest(".sheet-grabber")) return true;
    if (presentation !== "player") return false;
    if (target.closest("button, a, input, select, textarea, label, [role='button'], [role='slider'], [contenteditable], [data-sheet-no-drag]")) return false;
    // A smaller screen can scroll the player. Never steal a gesture that
    // began below the top, including a nested scrolling region.
    for (let node: HTMLElement | null = target; node && node !== dialog; node = node.parentElement) {
      if (node.scrollTop > 0) return false;
    }
    return true;
  }

  function startDrag(target: EventTarget | null, x: number, y: number, identifier: number, source: "touch" | "pointer") {
    suppressGrabberClick = false;
    if (!canStartDrag(target)) return;
    dragIdentifier = identifier;
    dragSource = source;
    dragTarget = target;
    dragStartX = x;
    dragStart = dragLastY = y;
    dragLastTime = performance.now();
    dragVelocity = 0;
    dragged = false;
  }

  function moveDrag(x: number, y: number, event: Event) {
    if (dragIdentifier === null) return;
    const delta = y - dragStart;
    const sideways = Math.abs(x - dragStartX);
    if (!dragging) {
      // Lock to the initial direction. Horizontal movement and upward scroll
      // must not turn into a dismissal after the finger changes direction.
      if (delta < -5 || (sideways > 5 && sideways > delta)) { resetDrag(); return; }
      if (delta <= 0 || sideways > delta) return;
      if (!event.cancelable) { resetDrag(); return; }
      // Safari chooses native scrolling from the first touchmove. Claim even
      // a tiny downward start before applying the visual movement threshold.
      event.preventDefault();
      if (delta <= 5) return;
      dragging = true;
      dragged = true;
    }
    event.preventDefault();
    const now = performance.now();
    dragVelocity = (y - dragLastY) / Math.max(1, now - dragLastTime);
    dragLastY = y;
    dragLastTime = now;
    dragOffset = Math.max(0, delta);
  }

  function resetDrag() {
    dragging = false;
    dragIdentifier = null;
    dragSource = null;
    dragTarget = null;
    dragOffset = 0;
  }

  function endDrag(cancelled = false) {
    if (dragIdentifier === null) return;
    const now = performance.now();
    const velocity = now - dragLastTime < 120 ? dragVelocity : 0;
    const dismiss = !cancelled && dragging && (dragOffset > 80 || (dragOffset > 35 && velocity > 0.5));
    suppressGrabberClick = dragged;
    dragging = false;
    dragIdentifier = null;
    dragSource = null;
    dragTarget = null;
    if (dismiss) onClose();
    else dragOffset = 0;
  }

  function touchStart(event: TouchEvent) {
    if (event.touches.length !== 1) { endDrag(true); return; }
    const touch = event.touches[0];
    startDrag(event.target, touch.clientX, touch.clientY, touch.identifier, "touch");
  }
  function touchMove(event: TouchEvent) {
    if (dragSource !== "touch") return;
    if (event.touches.length !== 1) { endDrag(true); return; }
    const touch = event.touches[0];
    if (touch.identifier === dragIdentifier) moveDrag(touch.clientX, touch.clientY, event);
  }
  function touchEnd(event: TouchEvent) {
    if (dragSource === "touch" && Array.from(event.changedTouches).some(touch => touch.identifier === dragIdentifier)) endDrag();
  }
  function touchCancel() { if (dragSource === "touch") endDrag(true); }

  // Touch uses touchmove to negotiate native scrolling. Keep pen gestures and
  // the grabber's pointer interaction without processing a touch twice.
  function pointerStart(event: PointerEvent) {
    suppressGrabberClick = false;
    if (event.pointerType === "touch" || event.pointerType === "mouse" || !event.isPrimary) return;
    startDrag(event.target, event.clientX, event.clientY, event.pointerId, "pointer");
    if (dragIdentifier !== null) dragTarget?.setPointerCapture(event.pointerId);
  }
  function pointerMove(event: PointerEvent) {
    if (dragSource === "pointer" && event.pointerId === dragIdentifier) moveDrag(event.clientX, event.clientY, event);
  }
  function pointerEnd(event: PointerEvent) {
    if (dragSource === "pointer" && event.pointerId === dragIdentifier) endDrag();
  }
  function pointerCancel() { if (dragSource === "pointer") endDrag(true); }

  function suppressDragClick(event: MouseEvent) {
    if (suppressGrabberClick && event.detail !== 0) {
      suppressGrabberClick = false;
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }

</script>

<dialog
  bind:this={dialog}
  in:sheetEnter
  out:sheetExit
  onoutrostart={() => { leaving = true; }}
  class="mobile-sheet"
  class:player-sheet={wide}
  class:native-player-sheet={presentation === "player"}
  class:native-queue-sheet={presentation === "queue"}
  class:compact-sheet={compact}
  class:full-sheet={full}
  class:dragging
  class:sheet-presented={presented}
  class:sheet-leaving={leaving}
  style:transform={dragOffset ? `translateY(${dragOffset}px)` : undefined}
  aria-label={title}
  oncancel={(event) => { event.preventDefault(); onClose(); }}
  onclick={(event) => { if (event.target === dialog) onClose(); }}
>
  <div class="mobile-sheet-panel">
    {#if background}<div class="mobile-sheet-background">{@render background()}</div>{/if}
    <button class="sheet-grabber" type="button" aria-label={`Close ${title}`} onclick={onClose}>
      <span class="sheet-handle" aria-hidden="true"></span>
    </button>
    {#if presentation !== "player"}
      <header class="mobile-sheet-header">
        {#if leading}<div class="mobile-sheet-leading">{@render leading()}</div>{/if}
        <h2>{title}</h2>
        <div class="mobile-sheet-trailing">
          {#if trailing}{@render trailing()}{/if}
          <button class="mobile-text-button" type="button" onclick={onClose}>Done</button>
        </div>
      </header>
    {/if}
    <div class="mobile-sheet-body">{@render children()}</div>
  </div>
</dialog>
