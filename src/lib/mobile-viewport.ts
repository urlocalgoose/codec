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

// Browser chrome and keyboards can resize the visible area without resizing
// the layout viewport. Keep layout stable during pinch zoom: zoom must magnify
// existing content, not rearrange it or move controls away from the user's finger.
export function resolveViewportGeometry(input: ViewportInput): ViewportGeometry | null {
  if (!Number.isFinite(input.layoutHeight) || input.layoutHeight <= 0) return null;
  const visual = input.visual;
  if (visual && Number.isFinite(visual.scale) && Math.abs(visual.scale - 1) > 0.001) return null;
  const height = visual && Number.isFinite(visual.height) && visual.height > 0
    ? Math.min(visual.height, input.layoutHeight) : input.layoutHeight;
  const top = visual && Number.isFinite(visual.offsetTop)
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
    const next = resolveViewportGeometry({ layoutHeight: win.innerHeight, visual, editableFocused });
    if (!next) return;
    for (const [property, value] of [[properties[0], next.height], [properties[1], next.top], [properties[2], next.bottom]] as const) {
      const pixels = `${value}px`;
      if (root.style.getPropertyValue(property) !== pixels) root.style.setProperty(property, pixels);
    }
    if (next.keyboardOpen) root.dataset.keyboardOpen = "true";
    else delete root.dataset.keyboardOpen;
  };
  const schedule = () => { if (!frame && !disposed) frame = win.requestAnimationFrame(update); };
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
    for (const property of properties) root.style.removeProperty(property);
    delete root.dataset.displayMode;
    delete root.dataset.standalone;
    delete root.dataset.keyboardOpen;
  };
}
