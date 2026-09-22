export type SwipeSide = "leading" | "trailing";
export type SwipeAction = {
  id: string;
  label: string;
  ariaLabel?: string;
  icon: "next" | "last" | "like" | "unlike" | "download" | "remove-download" | "remove" | "delete";
  tone?: "accent" | "muted" | "danger";
  disabled?: boolean;
  run: () => void;
};

export const SWIPE_ACTION_WIDTH = 76;
export const ROW_SWIPE_SLOP = 8;
export type RowSwipeOptions = {
  width: number;
  leadingWidth: number;
  trailingWidth: number;
  allowLeadingFull: boolean;
  allowTrailingFull: boolean;
};
export type RowSwipe = {
  startX: number; startY: number; initialSide: SwipeSide | null;
  initialOffset: number; offset: number; travel: number;
  lastX: number; lastTime: number; velocity: number;
  axis: "pending" | "horizontal" | "vertical";
};

export function swipeSide(offset: number): SwipeSide | null {
  return offset > 0 ? "leading" : offset < 0 ? "trailing" : null;
}

export function swipeOffset(side: SwipeSide | null, options: RowSwipeOptions): number {
  return side === "leading" ? options.leadingWidth : side === "trailing" ? -options.trailingWidth : 0;
}

export function beginRowSwipe(x: number, y: number, time: number, side: SwipeSide | null, options: RowSwipeOptions): RowSwipe {
  const offset = swipeOffset(side, options);
  return { startX: x, startY: y, initialSide: side, initialOffset: offset, offset,
    travel: 0, lastX: x, lastTime: time, velocity: 0, axis: "pending" };
}

export function fullSwipeThreshold(options: RowSwipeOptions, side: SwipeSide): number {
  const actionWidth = side === "leading" ? options.leadingWidth : options.trailingWidth;
  return Math.max(180, options.width * .6, actionWidth + 40);
}

export function updateRowSwipe(swipe: RowSwipe, x: number, y: number, time: number, options: RowSwipeOptions): RowSwipe {
  const dx = x - swipe.startX, dy = y - swipe.startY;
  let axis = swipe.axis;
  if (axis === "pending" && Math.max(Math.abs(dx), Math.abs(dy)) >= ROW_SWIPE_SLOP) {
    // Resolve ambiguous diagonals as native vertical scrolling and never
    // switch directions after the browser has started that scroll.
    axis = Math.abs(dx) > Math.abs(dy) * 1.15 ? "horizontal" : "vertical";
  }
  if (axis !== "horizontal") return { ...swipe, axis, travel: dx };
  const raw = swipe.initialOffset + dx;
  const side = swipeSide(raw);
  const revealWidth = side === "leading" ? options.leadingWidth : options.trailingWidth;
  const fullAllowed = side === "leading" ? options.allowLeadingFull : options.allowTrailingFull;
  let magnitude = Math.abs(raw);
  if (!revealWidth) magnitude = 0;
  else if (!fullAllowed && magnitude > revealWidth) magnitude = revealWidth + Math.min(32, (magnitude - revealWidth) * .15);
  const offset = Math.sign(raw) * Math.min(options.width, magnitude);
  return { ...swipe, axis, offset, travel: dx, lastX: x, lastTime: time,
    velocity: (x - swipe.lastX) / Math.max(1, time - swipe.lastTime) };
}

export function fullSwipeSide(swipe: RowSwipe, options: RowSwipeOptions): SwipeSide | null {
  const side = swipeSide(swipe.offset);
  if (swipe.axis !== "horizontal" || !side) return null;
  const enabled = side === "leading" ? options.allowLeadingFull : options.allowTrailingFull;
  const threshold = fullSwipeThreshold(options, side);
  // Opening an existing action strip must not turn a short extra drag into a
  // destructive full swipe. Require deliberate finger travel as well.
  return enabled && Math.abs(swipe.offset) >= threshold && Math.abs(swipe.travel) >= threshold ? side : null;
}

export function finishRowSwipe(swipe: RowSwipe, time: number, options: RowSwipeOptions, canceled = false): { openSide: SwipeSide | null; actionSide: SwipeSide | null } {
  if (canceled || swipe.axis !== "horizontal") return { openSide: swipe.initialSide, actionSide: null };
  const actionSide = fullSwipeSide(swipe, options);
  if (actionSide) return { openSide: null, actionSide };
  const side = swipeSide(swipe.offset);
  if (!side) return { openSide: null, actionSide: null };
  const width = side === "leading" ? options.leadingWidth : options.trailingWidth;
  const outwardVelocity = (side === "leading" ? 1 : -1) * (time - swipe.lastTime < 120 ? swipe.velocity : 0);
  const offset = Math.abs(swipe.offset);
  const open = outwardVelocity > .45 && offset > 12 ? true
    : outwardVelocity < -.45 && offset < width - 12 ? false : offset >= width / 2;
  return { openSide: open ? side : null, actionSide: null };
}
