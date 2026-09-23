import { describe, expect, test } from "bun:test";
import { isInstalledDisplayMode, observeMobileViewport, resolveViewportGeometry } from "./mobile-viewport";

describe("mobile viewport policy", () => {
  test("detects both standalone standards without inferring installation from mobile size", () => {
    expect(isInstalledDisplayMode(false)).toBe(false);
    expect(isInstalledDisplayMode(false, false)).toBe(false);
    expect(isInstalledDisplayMode(true, false)).toBe(true);
    expect(isInstalledDisplayMode(false, true)).toBe(true);
  });
  test("fills the complete installed viewport without subtracting safe areas", () => {
    expect(resolveViewportGeometry({ layoutHeight: 844, editableFocused: false }))
      .toEqual({ height: 844, top: 0, bottom: 0, keyboardOpen: false });
  });
  test("follows CSS viewport changes without depending on lagging Safari visual measurements", () => {
    for (const height of [744, 700, 664, 744]) {
      expect(resolveViewportGeometry({ layoutHeight: height, visual: { height: 664, offsetTop: 0, scale: 1 }, editableFocused: false }))
        .toEqual({ height, top: 0, bottom: 0, keyboardOpen: false });
    }
  });
  test("an undersized standalone VisualViewport cannot leave a strip below the app", () => {
    expect(resolveViewportGeometry({ layoutHeight: 874, visual: { height: 780, offsetTop: 20, scale: 1 }, editableFocused: false }))
      .toEqual({ height: 874, top: 0, bottom: 0, keyboardOpen: false });
  });
  test("blur restores the full viewport even before the keyboard reports its dismissal", () => {
    expect(resolveViewportGeometry({ layoutHeight: 874, visual: { height: 430, offsetTop: 80, scale: 1 }, editableFocused: false }))
      .toEqual({ height: 874, top: 0, bottom: 0, keyboardOpen: false });
  });
  test("keeps controls within the keyboard's visible area, including Safari focus panning", () => {
    expect(resolveViewportGeometry({ layoutHeight: 844, visual: { height: 430, offsetTop: 80, scale: 1 }, editableFocused: true }))
      .toEqual({ height: 430, top: 80, bottom: 334, keyboardOpen: true });
  });
  test("restores the full screen after dismissal or orientation changes", () => {
    for (const height of [844, 390]) {
      expect(resolveViewportGeometry({ layoutHeight: height, visual: { height, offsetTop: 0, scale: 1 }, editableFocused: true }))
        .toEqual({ height, top: 0, bottom: 0, keyboardOpen: false });
    }
  });
  test("preserves existing geometry during pinch zoom instead of shrinking the UI", () => {
    expect(resolveViewportGeometry({ layoutHeight: 844, visual: { height: 422, offsetTop: 100, scale: 2 }, editableFocused: true })).toBeNull();
  });
  test("ignores transient invalid measurements and clamps elastic overscroll", () => {
    expect(resolveViewportGeometry({ layoutHeight: 0, editableFocused: false })).toBeNull();
    expect(resolveViewportGeometry({ layoutHeight: NaN, editableFocused: false })).toBeNull();
    expect(resolveViewportGeometry({ layoutHeight: 844, visual: { height: 0, offsetTop: -20, scale: 1 }, editableFocused: false }))
      .toEqual({ height: 844, top: 0, bottom: 0, keyboardOpen: false });
    expect(resolveViewportGeometry({ layoutHeight: 844, visual: { height: 900, offsetTop: 20, scale: 1 }, editableFocused: false }))
      .toEqual({ height: 844, top: 0, bottom: 0, keyboardOpen: false });
  });
  test("does not add keyboard-specific padding changes for subpixel rounding", () => {
    expect(resolveViewportGeometry({ layoutHeight: 844, visual: { height: 843.5, offsetTop: 0, scale: 1 }, editableFocused: true })?.keyboardOpen).toBe(false);
  });
});

function viewportFixture() {
  const styles = new Map<string, string>();
  const root = { dataset: {} as Record<string, string>, style: {
    getPropertyValue: (name: string) => styles.get(name) ?? "",
    setProperty: (name: string, value: string) => styles.set(name, value),
    removeProperty: (name: string) => styles.delete(name)
  } };
  const frames = new Map<number, FrameRequestCallback>();
  let sequence = 0;
  const visual = Object.assign(new EventTarget(), { height: 844, offsetTop: 0, scale: 1 });
  const css = { height: 844, mounted: false };
  const probe = { dataset: {} as Record<string, string>, style: { cssText: "" },
    setAttribute: () => {}, getBoundingClientRect: () => ({ height: css.height }), remove: () => { css.mounted = false; } };
  let resized: (() => void) | undefined;
  const mode = Object.assign(new EventTarget(), { matches: false });
  const doc = Object.assign(new EventTarget(), {
    documentElement: root, visibilityState: "visible", activeElement: null as unknown,
    createElement: () => probe, body: { append: () => { css.mounted = true; } }
  });
  const win = Object.assign(new EventTarget(), {
    innerHeight: 844, visualViewport: visual, navigator: { standalone: false },
    matchMedia: () => mode,
    ResizeObserver: class {
      constructor(callback: () => void) { resized = callback; }
      observe() {}
      disconnect() { resized = undefined; }
    },
    requestAnimationFrame: (callback: FrameRequestCallback) => { frames.set(++sequence, callback); return sequence; },
    cancelAnimationFrame: (id: number) => frames.delete(id)
  });
  return { root, styles, visual, mode, doc, win, frames, css, resize: () => resized?.(),
    flush: () => { const pending = [...frames.values()]; frames.clear(); pending.forEach(fn => fn(0)); },
    start: () => observeMobileViewport(win as unknown as Window, doc as unknown as Document)
  };
}

describe("viewport observation lifecycle", () => {
  test("CSS resize replaces stale innerHeight/VisualViewport measurements and disconnects its probe", () => {
    const fixture = viewportFixture();
    const stop = fixture.start();
    fixture.win.innerHeight = 750;
    fixture.visual.height = 750;
    fixture.css.height = 874;
    fixture.mode.matches = true;
    fixture.mode.dispatchEvent(new Event("change"));
    fixture.resize();
    fixture.flush();
    expect(fixture.styles.get("--app-viewport-height")).toBe("874px");
    expect(fixture.root.dataset.displayMode).toBe("standalone");
    expect(fixture.css.mounted).toBe(true);
    stop();
    expect(fixture.css.mounted).toBe(false);
    fixture.resize();
    expect(fixture.frames.size).toBe(0);
  });
  test("updates from visual-only keyboard events and display-mode changes", () => {
    const fixture = viewportFixture();
    const stop = fixture.start();
    expect(fixture.root.dataset.displayMode).toBe("browser");
    expect(fixture.styles.get("--app-viewport-height")).toBe("844px");
    fixture.doc.activeElement = { isContentEditable: false, matches: () => true };
    fixture.visual.height = 430;
    fixture.visual.offsetTop = 80;
    fixture.doc.dispatchEvent(new Event("focusin"));
    fixture.visual.dispatchEvent(new Event("resize"));
    fixture.visual.dispatchEvent(new Event("scroll"));
    expect(fixture.frames.size).toBe(1);
    fixture.flush();
    expect(fixture.styles.get("--app-viewport-height")).toBe("430px");
    expect(fixture.styles.get("--app-viewport-top")).toBe("80px");
    expect(fixture.styles.get("--app-viewport-bottom")).toBe("334px");
    expect(fixture.root.dataset.keyboardOpen).toBe("true");
    fixture.mode.matches = true;
    fixture.mode.dispatchEvent(new Event("change"));
    fixture.flush();
    expect(fixture.root.dataset.displayMode).toBe("standalone");
    expect(fixture.root.dataset.standalone).toBe("true");
    stop();
  });

  test("retains the last geometry while zooming/backgrounded and removes all pending work on teardown", () => {
    const fixture = viewportFixture();
    const stop = fixture.start();
    fixture.visual.scale = 2;
    fixture.visual.height = 422;
    fixture.visual.dispatchEvent(new Event("resize"));
    fixture.flush();
    expect(fixture.styles.get("--app-viewport-height")).toBe("844px");
    fixture.doc.visibilityState = "hidden";
    fixture.visual.scale = 1;
    fixture.doc.dispatchEvent(new Event("visibilitychange"));
    fixture.flush();
    expect(fixture.styles.get("--app-viewport-height")).toBe("844px");
    fixture.doc.visibilityState = "visible";
    fixture.win.dispatchEvent(new Event("pageshow"));
    fixture.flush();
    expect(fixture.styles.get("--app-viewport-height")).toBe("844px");
    fixture.visual.dispatchEvent(new Event("resize"));
    stop();
    expect(fixture.frames.size).toBe(0);
    expect(fixture.styles.size).toBe(0);
    expect(fixture.root.dataset).toEqual({});
    fixture.win.dispatchEvent(new Event("resize"));
    fixture.visual.dispatchEvent(new Event("scroll"));
    fixture.mode.dispatchEvent(new Event("change"));
    fixture.doc.dispatchEvent(new Event("focusout"));
    expect(fixture.frames.size).toBe(0);
  });
});
