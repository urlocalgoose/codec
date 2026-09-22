import { expect, test } from "bun:test";
import { beginRowSwipe, finishRowSwipe, fullSwipeSide, fullSwipeThreshold, swipeOffset, updateRowSwipe, type RowSwipeOptions } from "./row-swipe";

const options: RowSwipeOptions = { width: 390, leadingWidth: 152, trailingWidth: 152, allowLeadingFull: true, allowTrailingFull: true };

test("both directions follow finger movement and settle at their actual action widths", () => {
  for (const direction of [-1, 1]) {
    const moved = updateRowSwipe(beginRowSwipe(200, 100, 0, null, options), 200 + direction * 90, 102, 200, options);
    expect(moved.offset).toBe(direction * 90);
    expect(finishRowSwipe(moved, 400, options)).toEqual({ openSide: direction > 0 ? "leading" : "trailing", actionSide: null });
  }
  expect(swipeOffset("leading", options)).toBe(152);
  expect(swipeOffset("trailing", options)).toBe(-152);
});

test("vertical and diagonal gestures remain scrolls, including later sideways movement", () => {
  for (const [x, y] of [[202, 112], [210, 110]]) {
    const scroll = updateRowSwipe(beginRowSwipe(200, 100, 0, null, options), x, y, 16, options);
    expect(scroll.axis).toBe("vertical");
    const changed = updateRowSwipe(scroll, 500, 115, 30, options);
    expect(changed.offset).toBe(0);
    expect(finishRowSwipe(changed, 40, options)).toEqual({ openSide: null, actionSide: null });
  }
});

test("a fast short flick only reveals actions, never invokes a full-swipe action", () => {
  const flick = updateRowSwipe(beginRowSwipe(200, 100, 0, null, options), 175, 100, 12, options);
  expect(finishRowSwipe(flick, 20, options)).toEqual({ openSide: "trailing", actionSide: null });
  expect(finishRowSwipe(flick, 200, options)).toEqual({ openSide: null, actionSide: null });
});

test("full swipe requires sixty percent of width and deliberate travel in either direction", () => {
  expect(fullSwipeThreshold(options, "leading")).toBe(234);
  for (const direction of [-1, 1]) {
    const side = direction > 0 ? "leading" : "trailing";
    const almost = updateRowSwipe(beginRowSwipe(200, 100, 0, null, options), 200 + direction * 233, 100, 250, options);
    expect(fullSwipeSide(almost, options)).toBeNull();
    const full = updateRowSwipe(almost, 200 + direction * 240, 101, 270, options);
    expect(finishRowSwipe(full, 300, options)).toEqual({ openSide: null, actionSide: side });
  }
});

test("wide strips and small screens cannot turn ordinary reveals into full swipes", () => {
  expect(fullSwipeThreshold({ ...options, width: 300 }, "leading")).toBe(192);
  expect(fullSwipeThreshold({ ...options, leadingWidth: 228 }, "leading")).toBe(268);
  const moved = updateRowSwipe(beginRowSwipe(100, 100, 0, "leading", options), 200, 100, 100, options);
  expect(moved.offset).toBe(252);
  expect(fullSwipeSide(moved, options)).toBeNull();
});

test("disallowed full swipes rubber-band beyond the strip but never execute", () => {
  const noFull = { ...options, allowTrailingFull: false };
  const moved = updateRowSwipe(beginRowSwipe(300, 100, 0, null, noFull), -500, 100, 500, noFull);
  expect(moved.offset).toBe(-184);
  expect(finishRowSwipe(moved, 510, noFull)).toEqual({ openSide: "trailing", actionSide: null });
});

test("unsupported directions remain closed and a closing swipe does not invoke another action", () => {
  const trailingOnly = { ...options, leadingWidth: 0 };
  const unsupported = updateRowSwipe(beginRowSwipe(100, 100, 0, null, trailingOnly), 390, 100, 100, trailingOnly);
  expect(unsupported.offset).toBe(0);
  expect(finishRowSwipe(unsupported, 120, trailingOnly)).toEqual({ openSide: null, actionSide: null });
  const close = updateRowSwipe(beginRowSwipe(100, 100, 0, "trailing", options), 225, 100, 150, options);
  expect(finishRowSwipe(close, 160, options)).toEqual({ openSide: null, actionSide: null });
});

test("cancellation never invokes even an armed full swipe and restores the starting side", () => {
  for (const side of [null, "leading", "trailing"] as const) {
    const swipe = updateRowSwipe(beginRowSwipe(100, 100, 0, side, options), 450, 101, 200, options);
    expect(finishRowSwipe(swipe, 210, options, true)).toEqual({ openSide: side, actionSide: null });
  }
});
