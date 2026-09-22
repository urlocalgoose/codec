/** Queue gestures are local presentation state; these helpers never mutate playback. */
export const QUEUE_REVEAL_WIDTH = 88;
export const QUEUE_ROW_HEIGHT = 86;
export type QueueGroup = "manual" | "upcoming";

export function queueEntryKeys(tracks: readonly { id: string; fingerprint: string; path: string }[], group: QueueGroup): string[] {
  const occurrences = new Map<string, number>();
  return tracks.map(track => {
    const identity = JSON.stringify([track.id, track.fingerprint, track.path]);
    const occurrence = occurrences.get(identity) ?? 0;
    occurrences.set(identity, occurrence + 1);
    return JSON.stringify([group, identity, occurrence]);
  });
}

export type QueueSwipe = {
  startX: number; startY: number; initialOffset: number; offset: number;
  lastX: number; lastTime: number; velocity: number;
  axis: "pending" | "horizontal" | "vertical";
};

export function beginQueueSwipe(x: number, y: number, time: number, open = false): QueueSwipe {
  const offset = open ? -QUEUE_REVEAL_WIDTH : 0;
  return { startX: x, startY: y, initialOffset: offset, offset, lastX: x, lastTime: time, velocity: 0, axis: "pending" };
}

export function updateQueueSwipe(swipe: QueueSwipe, x: number, y: number, time: number): QueueSwipe {
  const dx = x - swipe.startX, dy = y - swipe.startY;
  let axis = swipe.axis;
  if (axis === "pending" && Math.max(Math.abs(dx), Math.abs(dy)) >= 8) {
    // Resolve ambiguous diagonals toward scrolling, then keep that decision.
    axis = Math.abs(dx) > Math.abs(dy) * 1.15 ? "horizontal" : "vertical";
  }
  if (axis !== "horizontal") return { ...swipe, axis };
  return {
    ...swipe, axis, offset: Math.min(0, Math.max(-QUEUE_REVEAL_WIDTH, swipe.initialOffset + dx)),
    velocity: (x - swipe.lastX) / Math.max(1, time - swipe.lastTime), lastX: x, lastTime: time,
  };
}

export function finishQueueSwipe(swipe: QueueSwipe, time: number, cancelled = false): boolean {
  if (cancelled || swipe.axis !== "horizontal") return swipe.initialOffset < 0;
  const velocity = time - swipe.lastTime < 120 ? swipe.velocity : 0;
  if (velocity < -.45 && swipe.offset < -12) return true;
  if (velocity > .45 && swipe.offset > -QUEUE_REVEAL_WIDTH + 12) return false;
  return swipe.offset <= -QUEUE_REVEAL_WIDTH / 2;
}

/** Pixel delta for a frame, bounded even after a stalled/backgrounded frame. */
export function queueEdgeScroll(y: number, top: number, bottom: number, elapsedMs: number): number {
  if (bottom <= top) return 0;
  const edge = Math.min(56, (bottom - top) / 4);
  const proximity = y < top + edge ? -Math.min(1, (top + edge - y) / edge)
    : y > bottom - edge ? Math.min(1, (y - bottom + edge) / edge) : 0;
  return Math.sign(proximity) * proximity * proximity * 640 * Math.min(32, Math.max(0, elapsedMs)) / 1000;
}

export function queueDropIndex(y: number, groupTop: number, count: number): number {
  return count ? Math.max(0, Math.min(count - 1, Math.floor((y - groupTop) / QUEUE_ROW_HEIGHT))) : -1;
}

/** A changing queue invalidates a drag, including indistinguishable duplicate occurrences. */
export function queueOrderMatches(start: readonly string[], current: readonly string[]): boolean {
  return start.length === current.length && start.every((key, index) => key === current[index]);
}
