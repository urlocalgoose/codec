import { derivedPlaybackPosition, type PlaybackStateV2 } from "./sync";

/** Server receipt time and local buffering do not constitute a seek. Compare
 * both playback clocks at the same instant to identify a transport change. */
export function playbackPositionChanged(previous: PlaybackStateV2 | null, next: PlaybackStateV2): boolean {
  if (!previous || previous.active_device_id !== next.active_device_id || previous.track?.fingerprint !== next.track?.fingerprint) {
    return true;
  }
  const previousPosition = derivedPlaybackPosition(previous, next.clock.updated_at_ms);
  return Math.abs(previousPosition - next.clock.position_seconds) > 0.05;
}
