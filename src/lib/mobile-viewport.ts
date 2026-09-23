export type ViewportGeometry = {
  height: number;
  top: number;
  bottom: number;
  keyboardOpen: boolean;
};

type ViewportInput = {
  layoutHeight: number;
  visual?: { height: number; offsetTop: number; scale: number } | null;
  editableFocused: boolean;
};

export function isInstalledDisplayMode(displayModeStandalone: boolean, navigatorStandalone?: boolean): boolean {
  return displayModeStandalone || navigatorStandalone === true;
}

// CSS supplies the normal viewport height: dynamic in a browser, full-height
// in Home Screen mode. iOS can keep an undersized VisualViewport after opening
// a saved app or dismissing its keyboard. Only a focused editor should let that
// API shrink/pan the shell. Pinch zoom must magnify the existing layout.
export function resolveViewportGeometry(input: ViewportInput): ViewportGeometry | null {
  if (!Number.isFinite(input.layoutHeight) || input.layoutHeight <= 0) return null;
  const visual = input.visual;
  if (visual && Number.isFinite(visual.scale) && Math.abs(visual.scale - 1) > 0.001) return null;
  const height = input.editableFocused && visual && Number.isFinite(visual.height) && visual.height > 0
    ? Math.min(visual.height, input.layoutHeight) : input.layoutHeight;
  const top = input.editableFocused && visual && Number.isFinite(visual.offsetTop)
    ? Math.min(Math.max(0, visual.offsetTop), input.layoutHeight - height) : 0;
  return {
    height,
    top,
    bottom: Math.max(0, input.layoutHeight - top - height),
    // A one-pixel tolerance covers fractional viewport rounding. No keyboard
    // model, browser name or device-specific toolbar height is assumed.
    keyboardOpen: input.editableFocused && input.layoutHeight - height > 1
  };
}

export function observeMobileViewport(win: Window, doc: Document): () => void {
  const root = doc.documentElement;
  const standalone = win.matchMedia("(display-mode: standalone)");
  const visual = win.visualViewport;
  // Measure an independent CSS viewport, not the app whose height we set.
  // A ResizeObserver also catches toolbar changes which don't emit window.resize.
  const probe = doc.createElement("div");
  probe.dataset.codecViewportProbe = "";
  probe.setAttribute("aria-hidden", "true");
  probe.style.cssText = "position:fixed;top:0;left:0;width:0;height:var(--app-layout-height,100dvh);visibility:hidden;pointer-events:none;contain:strict;";
  doc.body.append(probe);
  let frame = 0;
  let disposed = false;
  const properties = ["--app-viewport-height", "--app-viewport-top", "--app-viewport-bottom"];
  const update = () => {
    frame = 0;
    if (disposed || doc.visibilityState === "hidden") return;
    const installed = isInstalledDisplayMode(standalone.matches,
      (win.navigator as Navigator & { standalone?: boolean }).standalone);
    root.dataset.displayMode = installed ? "standalone" : "browser";
    if (installed) root.dataset.standalone = "true";
    else delete root.dataset.standalone;
    const active = doc.activeElement as HTMLElement | null;
    const editableFocused = Boolean(active && (
      active.isContentEditable || active.matches("textarea:not([readonly]):not([disabled]), input:not([readonly]):not([disabled]):is([type=text],[type=search],[type=url],[type=email],[type=tel],[type=password],[type=number],:not([type]))")
    ));
    const cssHeight = probe.getBoundingClientRect().height;
    const next = resolveViewportGeometry({ layoutHeight: cssHeight || win.innerHeight, visual, editableFocused });
    if (!next) return;
    for (const [property, value] of [[properties[0], next.height], [properties[1], next.top], [properties[2], next.bottom]] as const) {
      const pixels = `${value}px`;
      if (root.style.getPropertyValue(property) !== pixels) root.style.setProperty(property, pixels);
    }
    if (next.keyboardOpen) root.dataset.keyboardOpen = "true";
    else delete root.dataset.keyboardOpen;
  };
  const schedule = () => { if (!frame && !disposed) frame = win.requestAnimationFrame(update); };
  const resize = new (win as Window & { ResizeObserver: typeof ResizeObserver }).ResizeObserver(schedule);
  resize.observe(probe);
  const events: [EventTarget, string][] = [
    [win, "resize"], [win, "pageshow"], [win, "orientationchange"],
    [doc, "visibilitychange"], [doc, "focusin"], [doc, "focusout"],
    [standalone, "change"]
  ];
  if (visual) events.push([visual, "resize"], [visual, "scroll"]);
  for (const [target, event] of events) target.addEventListener(event, schedule);
  update();
  return () => {
    disposed = true;
    win.cancelAnimationFrame(frame);
    for (const [target, event] of events) target.removeEventListener(event, schedule);
    resize.disconnect();
    probe.remove();
    for (const property of properties) root.style.removeProperty(property);
    delete root.dataset.displayMode;
    delete root.dataset.standalone;
    delete root.dataset.keyboardOpen;
  };
}
