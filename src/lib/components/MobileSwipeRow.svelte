<script module lang="ts">
  let clearLongPressClick: (() => void) | undefined;

  function guardLongPressRelease(pointerId: number) {
    clearLongPressClick?.();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const cleanup = () => {
      clearTimeout(timer);
      document.removeEventListener("click", click, true);
      document.removeEventListener("pointerdown", cleanup, true);
      document.removeEventListener("keydown", cleanup, true);
      document.removeEventListener("pointerup", released, true);
      document.removeEventListener("pointercancel", released, true);
      document.removeEventListener("visibilitychange", hidden);
      window.removeEventListener("blur", cleanup);
      if (clearLongPressClick === cleanup) clearLongPressClick = undefined;
    };
    const click = (event: MouseEvent) => {
      if (event.detail === 0) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      cleanup();
    };
    const released = (event: PointerEvent) => {
      if (event.pointerId !== pointerId) return;
      clearTimeout(timer);
      timer = setTimeout(cleanup, 700);
    };
    const hidden = () => { if (document.visibilityState === "hidden") cleanup(); };
    // Opening a dialog can retarget the original release click to its first
    // action. Keep this one-shot guard outside the row's lifecycle so recycling
    // that row cannot activate the dialog. Any fresh input is intentional.
    clearLongPressClick = cleanup;
    document.addEventListener("click", click, true);
    document.addEventListener("pointerdown", cleanup, true);
    document.addEventListener("keydown", cleanup, true);
    document.addEventListener("pointerup", released, true);
    document.addEventListener("pointercancel", released, true);
    document.addEventListener("visibilitychange", hidden);
    window.addEventListener("blur", cleanup);
  }
</script>

<script lang="ts">
  import { onMount, untrack, type Snippet } from "svelte";
  import { CircleArrowDown, CircleMinus, Heart, HeartOff, ListEnd, ListStart, Trash2 } from "lucide-svelte";
  import { beginRowSwipe, finishRowSwipe, fullSwipeSide, ROW_SWIPE_SLOP, SWIPE_ACTION_WIDTH, swipeSide, updateRowSwipe, type RowSwipe, type RowSwipeOptions, type SwipeAction, type SwipeSide } from "$lib/row-swipe";

  let { identity, leading = [], trailing = [], children, disabled = false,
    allowLeadingFull = true, allowTrailingFull = true, openSide = null, onOpenChange, onLongPress }: {
    identity: string;
    leading?: SwipeAction[];
    trailing?: SwipeAction[];
    children: Snippet;
    disabled?: boolean;
    allowLeadingFull?: boolean;
    allowTrailingFull?: boolean;
    openSide?: SwipeSide | null;
    onOpenChange: (side: SwipeSide | null) => void;
    onLongPress?: () => void;
  } = $props();

  let row: HTMLDivElement;
  let content: HTMLDivElement;
  let mobile = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let suppressClickUntil = 0;
  let listening = false;
  let previousIdentity = "";
  let gesture = $state<{
    identity: string; pointerId: number; pointerType: string; swipe: RowSwipe;
    options: RowSwipeOptions; expectedSide: SwipeSide | null; longPressed: boolean;
  } | null>(null);
  const leadingWidth = $derived(leading.length * SWIPE_ACTION_WIDTH);
  const trailingWidth = $derived(trailing.length * SWIPE_ACTION_WIDTH);
  const restingOffset = $derived(openSide === "leading" ? leadingWidth : openSide === "trailing" ? -trailingWidth : 0);
  const offset = $derived(gesture?.swipe.offset ?? restingOffset);
  const visibleSide = $derived(swipeSide(offset));
  const fullSide = $derived(gesture ? fullSwipeSide(gesture.swipe, gesture.options) : null);
  const actionIdentity = $derived(JSON.stringify([identity, disabled, allowLeadingFull, allowTrailingFull,
    leading.map(action => [action.id, action.icon, action.label, Boolean(action.disabled)]),
    trailing.map(action => [action.id, action.icon, action.label, Boolean(action.disabled)])]));

  $effect(() => {
    const next = actionIdentity;
    if ((previousIdentity && previousIdentity !== next) || disabled) untrack(() => cancel(true));
    previousIdentity = next;
  });
  $effect(() => {
    const next = openSide;
    untrack(() => { if (gesture && gesture.expectedSide !== next) cancel(false); });
  });

  function clearHold() { clearTimeout(timer); timer = undefined; }
  function suppressClick() { suppressClickUntil = performance.now() + 700; }
  function listen(active: boolean) {
    if (listening === active) return;
    listening = active;
    if (active) {
      window.addEventListener("pointermove", move, { passive: false });
      window.addEventListener("pointerup", end);
      window.addEventListener("pointercancel", cancelPointer);
    } else {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", cancelPointer);
    }
  }
  function reset(suppress = false) {
    clearHold();
    const pointerId = gesture?.pointerId;
    gesture = null;
    listen(false);
    if (suppress) suppressClick();
    if (pointerId !== undefined && row?.hasPointerCapture(pointerId)) row.releasePointerCapture(pointerId);
  }
  function cancel(close: boolean) {
    reset(Boolean(gesture));
    if (close && openSide) onOpenChange(null);
  }
  function options(): RowSwipeOptions {
    return { width: row.getBoundingClientRect().width, leadingWidth, trailingWidth,
      // Full swipe always means the first action, never a different fallback.
      allowLeadingFull: allowLeadingFull && Boolean(leading[0] && !leading[0].disabled),
      allowTrailingFull: allowTrailingFull && Boolean(trailing[0] && !trailing[0].disabled) };
  }
  function isForegroundTarget(target: EventTarget | null): target is Element {
    if (!(target instanceof Element) || !content.contains(target)) return false;
    const control = target.closest("button,a,input,select,textarea,[role=button],[role=slider],[contenteditable],[data-swipe-no-drag]");
    // A primary row button is the gesture surface; controls nested inside it
    // retain their own tap/drag semantics (menus, likes, reorder, etc.).
    return !control || control === content.firstElementChild;
  }
  function start(event: PointerEvent) {
    if (!mobile || disabled) return;
    if (!event.isPrimary || event.button !== 0) {
      cancel(true);
      if (event.isPrimary) suppressClickUntil = 0;
      return;
    }
    if (!isForegroundTarget(event.target)) return;
    reset();
    // A fresh press is intentional; only the synthesized click belonging to
    // the previous swipe/hold should be swallowed.
    suppressClickUntil = 0;
    const config = options();
    gesture = { identity, pointerId: event.pointerId, pointerType: event.pointerType,
      swipe: beginRowSwipe(event.clientX, event.clientY, performance.now(), openSide, config),
      options: config, expectedSide: openSide, longPressed: false };
    listen(true);
    if (event.pointerType === "touch" && onLongPress) {
      timer = setTimeout(() => {
        if (!gesture || gesture.identity !== identity || gesture.swipe.axis !== "pending") return;
        gesture = { ...gesture, longPressed: true, expectedSide: null };
        guardLongPressRelease(gesture.pointerId);
        clearHold(); suppressClick(); onOpenChange(null); onLongPress?.();
      }, 450);
    }
  }
  function move(event: PointerEvent) {
    if (!gesture || gesture.pointerId !== event.pointerId || gesture.longPressed) return;
    if (gesture.identity !== identity || disabled) { cancel(true); return; }
    const next = updateRowSwipe(gesture.swipe, event.clientX, event.clientY, performance.now(), gesture.options);
    if (Math.hypot(event.clientX - next.startX, event.clientY - next.startY) >= ROW_SWIPE_SLOP) clearHold();
    let expectedSide = gesture.expectedSide;
    if (next.axis === "horizontal") {
      event.preventDefault();
      clearHold(); suppressClick();
      if (!row.hasPointerCapture(event.pointerId)) {
        try { row.setPointerCapture(event.pointerId); } catch { /* A synthetic/canceled pointer may already have ended. */ }
      }
      const side = swipeSide(next.offset);
      if (side !== expectedSide) {
        expectedSide = side;
        gesture = { ...gesture, swipe: next, expectedSide };
        onOpenChange(side);
        return;
      }
    }
    gesture = { ...gesture, swipe: next, expectedSide };
  }
  function finish(event: PointerEvent, canceled: boolean) {
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    const ended = gesture;
    const outcome = finishRowSwipe(ended.swipe, performance.now(), ended.options, canceled);
    reset(canceled || ended.longPressed || ended.swipe.axis !== "pending");
    if (ended.identity !== identity || disabled || ended.longPressed) return;
    onOpenChange(outcome.openSide);
    if (!canceled && outcome.actionSide) {
      const action = (outcome.actionSide === "leading" ? leading : trailing)[0];
      if (action && !action.disabled) action.run();
    }
  }
  function end(event: PointerEvent) { finish(event, false); }
  function cancelPointer(event: PointerEvent) { finish(event, true); }
  function interceptClick(event: MouseEvent) {
    if (!mobile || !isForegroundTarget(event.target)) return;
    if (event.detail !== 0 && performance.now() < suppressClickUntil) {
      event.preventDefault(); event.stopImmediatePropagation();
      return;
    }
    if (openSide) {
      event.preventDefault(); event.stopImmediatePropagation();
      cancel(false); onOpenChange(null);
    }
  }
  function contextMenu(event: MouseEvent) {
    if (!mobile) return;
    if (gesture?.longPressed || performance.now() < suppressClickUntil) {
      event.preventDefault(); event.stopImmediatePropagation();
    } else if (gesture?.pointerType === "touch") reset(true);
  }
  function invoke(action: SwipeAction, event: MouseEvent) {
    event.stopPropagation();
    if (!mobile || disabled || action.disabled) return;
    reset(true); onOpenChange(null); action.run();
    if (event.detail === 0) (content.firstElementChild as HTMLElement | null)?.focus({ preventScroll: true });
  }

  onMount(() => {
    const media = matchMedia("(max-width: 980px)");
    mobile = media.matches;
    const resized = () => { mobile = media.matches; cancel(true); };
    const hidden = () => { if (document.visibilityState === "hidden") cancel(true); };
    const escape = (event: KeyboardEvent) => {
      if (event.key === "Escape" && (openSide || gesture)) { event.preventDefault(); event.stopPropagation(); cancel(true); }
    };
    const lostCapture = (event: PointerEvent) => {
      // A touch begins with implicit capture on a child. Transferring it to
      // the stable wrapper emits a bubbling lost event from that old child.
      if (event.target === row && gesture?.pointerId === event.pointerId) cancelPointer(event);
    };
    const nativeDrag = (event: DragEvent) => {
      if (mobile && event.target instanceof Node && content.contains(event.target)) event.preventDefault();
    };
    row.addEventListener("pointerdown", start);
    row.addEventListener("click", interceptClick, true);
    row.addEventListener("contextmenu", contextMenu, true);
    row.addEventListener("lostpointercapture", lostCapture);
    row.addEventListener("dragstart", nativeDrag);
    row.addEventListener("keydown", escape);
    window.addEventListener("resize", resized);
    window.addEventListener("blur", resized);
    document.addEventListener("visibilitychange", hidden);
    media.addEventListener("change", resized);
    return () => {
      cancel(true);
      row.removeEventListener("pointerdown", start);
      row.removeEventListener("click", interceptClick, true);
      row.removeEventListener("contextmenu", contextMenu, true);
      row.removeEventListener("lostpointercapture", lostCapture);
      row.removeEventListener("dragstart", nativeDrag);
      row.removeEventListener("keydown", escape);
      window.removeEventListener("resize", resized);
      window.removeEventListener("blur", resized);
      document.removeEventListener("visibilitychange", hidden);
      media.removeEventListener("change", resized);
    };
  });
</script>

{#snippet symbol(action: SwipeAction)}
  {#if action.icon === "next"}<ListStart size={23} />
  {:else if action.icon === "last"}<ListEnd size={23} />
  {:else if action.icon === "like"}<Heart size={23} fill="currentColor" />
  {:else if action.icon === "unlike"}<HeartOff size={23} />
  {:else if action.icon === "download"}<CircleArrowDown size={23} />
  {:else if action.icon === "remove-download" || action.icon === "delete"}<Trash2 size={23} />
  {:else}<CircleMinus size={23} />{/if}
{/snippet}

<div bind:this={row} class="mobile-swipe-row" data-swipe-id={identity}
  class:swipe-active={offset !== 0} class:swipe-dragging={gesture?.swipe.axis === "horizontal"}
  class:swipe-full-leading={fullSide === "leading"} class:swipe-full-trailing={fullSide === "trailing"}
  style={`--row-swipe-x:${offset}px;--leading-swipe-width:${Math.max(leadingWidth, offset)}px;--trailing-swipe-width:${Math.max(trailingWidth, -offset)}px`}>
  {#if leading.length}
    <div class="row-swipe-actions leading-actions" class:swipe-visible={visibleSide === "leading"}
      aria-hidden={openSide !== "leading" || Boolean(gesture)} inert={openSide !== "leading" || Boolean(gesture)}>
      {#each leading as action (action.id)}
        <button type="button" data-swipe-action={action.id} data-tone={action.tone ?? "accent"}
          aria-label={action.ariaLabel ?? action.label} disabled={disabled || action.disabled} onclick={(event) => invoke(action, event)}>
          {@render symbol(action)}<span>{action.label}</span>
        </button>
      {/each}
    </div>
  {/if}
  {#if trailing.length}
    <div class="row-swipe-actions trailing-actions" class:swipe-visible={visibleSide === "trailing"}
      aria-hidden={openSide !== "trailing" || Boolean(gesture)} inert={openSide !== "trailing" || Boolean(gesture)}>
      {#each trailing as action (action.id)}
        <button type="button" data-swipe-action={action.id} data-tone={action.tone ?? "accent"}
          aria-label={action.ariaLabel ?? action.label} disabled={disabled || action.disabled} onclick={(event) => invoke(action, event)}>
          {@render symbol(action)}<span>{action.label}</span>
        </button>
      {/each}
    </div>
  {/if}
  <div bind:this={content} class="mobile-swipe-content">{@render children()}</div>
</div>
