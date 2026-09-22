/** Validate saved gain for the Tauri desktop player's media control. */
export function boundedVolume(value: unknown, fallback = .86): number {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(0, Math.min(number, 1)) : fallback;
}
