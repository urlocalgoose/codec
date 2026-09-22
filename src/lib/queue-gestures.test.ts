import { expect, test } from "bun:test";
import { beginQueueSwipe, finishQueueSwipe, queueDropIndex, queueEdgeScroll, queueEntryKeys, queueOrderMatches, updateQueueSwipe } from "./queue-gestures";

test("queue swipe tracks the finger before release and clamps at the action width", () => {
  const start = beginQueueSwipe(200, 100, 0);
  const middle = updateQueueSwipe(start, 170, 102, 50);
  expect(middle.axis).toBe("horizontal");
  expect(middle.offset).toBe(-30);
  expect(updateQueueSwipe(middle, -200, 103, 100).offset).toBe(-88);
  expect(updateQueueSwipe(middle, 250, 103, 100).offset).toBe(0);
});

test("vertical scroll and ambiguous diagonals cannot later become a swipe", () => {
  for (const [x, y] of [[198, 112], [190, 110]]) {
    const vertical = updateQueueSwipe(beginQueueSwipe(200, 100, 0), x, y, 16);
    const sideways = updateQueueSwipe(vertical, 100, 114, 40);
    expect(sideways.axis).toBe("vertical");
    expect(sideways.offset).toBe(0);
    expect(finishQueueSwipe(sideways, 50)).toBe(false);
  }
});

test("horizontal locking survives a later vertical wobble", () => {
  const swipe = updateQueueSwipe(beginQueueSwipe(200, 100, 0), 180, 101, 16);
  expect(updateQueueSwipe(swipe, 150, 170, 70).axis).toBe("horizontal");
});

test("short slow swipes settle closed, deliberate swipes open, and stale flick velocity expires", () => {
  const short = updateQueueSwipe(beginQueueSwipe(200, 100, 0), 180, 100, 100);
  expect(finishQueueSwipe(short, 110)).toBe(false);
  const flick = updateQueueSwipe(beginQueueSwipe(200, 100, 0), 180, 100, 16);
  expect(finishQueueSwipe(flick, 20)).toBe(true);
  expect(finishQueueSwipe(flick, 200)).toBe(false);
  const far = updateQueueSwipe(beginQueueSwipe(200, 100, 0), 145, 100, 200);
  expect(finishQueueSwipe(far, 400)).toBe(true);
});

test("a right swipe closes an open action and cancellation restores the starting state", () => {
  const opening = updateQueueSwipe(beginQueueSwipe(200, 100, 0), 130, 100, 100);
  expect(finishQueueSwipe(opening, 110, true)).toBe(false);
  const closing = updateQueueSwipe(beginQueueSwipe(200, 100, 0, true), 270, 100, 100);
  expect(finishQueueSwipe(closing, 110)).toBe(false);
  expect(finishQueueSwipe(closing, 110, true)).toBe(true);
});

const a = { id: "a", fingerprint: "fa", path: "/a" };
const b = { id: "b", fingerprint: "fb", path: "/b" };
test("row identity survives index shifts and metadata refreshes, with distinct duplicate occurrences", () => {
  const keys = queueEntryKeys([a, b, a], "manual");
  expect(new Set(keys).size).toBe(3);
  expect(queueEntryKeys([b, a, b, a], "manual")[1]).toBe(keys[0]);
  expect(queueEntryKeys([{ ...a }, { ...b }, { ...a }], "manual")).toEqual(keys);
  expect(queueEntryKeys([a], "upcoming")[0]).not.toBe(keys[0]);
});

test("mutated, transferred or reordered queues invalidate an in-flight drag", () => {
  const start = queueEntryKeys([a, b, a], "manual");
  expect(queueOrderMatches(start, queueEntryKeys([{ ...a }, b, a], "manual"))).toBe(true);
  for (const tracks of [[a, a], [b, a, a], [a, b, a, a]]) {
    expect(queueOrderMatches(start, queueEntryKeys(tracks, "manual"))).toBe(false);
  }
  expect(queueOrderMatches(start, queueEntryKeys([a, b, a], "upcoming"))).toBe(false);
});

test("edge scrolling continues on stationary frames, is symmetric, and bounds long frames", () => {
  expect(queueEdgeScroll(400, 100, 700, 16)).toBe(0);
  expect(queueEdgeScroll(698, 100, 700, 16)).toBeGreaterThan(0);
  expect(queueEdgeScroll(102, 100, 700, 16)).toBe(-queueEdgeScroll(698, 100, 700, 16));
  const held = Array.from({ length: 60 }, () => queueEdgeScroll(720, 100, 700, 16)).reduce((a, b) => a + b, 0);
  expect(held).toBeGreaterThan(500);
  expect(queueEdgeScroll(720, 100, 700, 10000)).toBe(20.48);
});

test("drop targets use logical rows beyond the virtualized window and clamp to their own group", () => {
  expect(queueDropIndex(690, -2000, 500)).toBe(31);
  expect(queueDropIndex(-200, 100, 20)).toBe(0);
  expect(queueDropIndex(9000, 100, 20)).toBe(19);
  expect(queueDropIndex(100, 100, 0)).toBe(-1);
});
