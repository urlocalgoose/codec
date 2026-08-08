import type { Track, TrackReference } from "./types";

export const PLAYBACK_SESSION_SCHEMA = "loud.playback.v1";

export interface PersistedPlaybackSession {
  schema: typeof PLAYBACK_SESSION_SCHEMA;
  root_path: string;
  saved_at: number;
  selected_view: string;
  current_track: TrackReference | null;
  queued_tracks: TrackReference[];
  playback_source: TrackReference[];
  playback_index: number;
  play_history: TrackReference[];
  current_time: number;
  audio_duration: number;
}

export function validTrackReference(value: unknown): value is TrackReference {
  if (!value || typeof value !== "object") {
    return false;
  }

  const candidate = value as Record<string, unknown>;
  return (
    typeof candidate.id === "string" &&
    typeof candidate.path === "string" &&
    typeof candidate.fingerprint === "string"
  );
}

export function validTrackReferences(value: unknown): TrackReference[] {
  return Array.isArray(value) ? value.filter(validTrackReference) : [];
}

export function validPlaybackSession(value: unknown): value is PersistedPlaybackSession {
  if (!value || typeof value !== "object") {
    return false;
  }

  const candidate = value as Partial<PersistedPlaybackSession>;
  return candidate.schema === PLAYBACK_SESSION_SCHEMA && typeof candidate.saved_at === "number";
}

/** Parse a persisted session, tolerating missing or malformed fields. */
export function parsePlaybackSession(raw: string | null, activeRootPath: string): PersistedPlaybackSession | null {
  if (!raw) {
    return null;
  }

  try {
    const session = JSON.parse(raw) as Partial<PersistedPlaybackSession>;
    if (session.schema !== PLAYBACK_SESSION_SCHEMA || session.root_path !== activeRootPath) {
      return null;
    }

    return {
      schema: PLAYBACK_SESSION_SCHEMA,
      root_path: session.root_path,
      saved_at: Number(session.saved_at) || 0,
      selected_view: typeof session.selected_view === "string" ? session.selected_view : "home",
      current_track: validTrackReference(session.current_track) ? session.current_track : null,
      queued_tracks: validTrackReferences(session.queued_tracks),
      playback_source: validTrackReferences(session.playback_source),
      playback_index: Number(session.playback_index) || 0,
      play_history: validTrackReferences(session.play_history),
      current_time: Number(session.current_time) || 0,
      audio_duration: Number(session.audio_duration) || 0
    };
  } catch {
    return null;
  }
}

export function clampIndex(index: number, length: number): number {
  if (length <= 0) {
    return 0;
  }

  return Math.max(0, Math.min(Math.trunc(index), length - 1));
}

export function clampPlaybackTime(time: number, track: Track | null): number {
  const duration = track?.duration_seconds;
  const safeTime = Number.isFinite(time) && time > 0 ? time : 0;
  return duration && duration > 0 ? Math.min(safeTime, Math.max(duration - 1, 0)) : safeTime;
}
