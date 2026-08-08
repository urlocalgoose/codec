import type {
  AlbumSummary,
  ArtistSummary,
  Library as MusicLibrary,
  Playlist,
  RepeatMode,
  Track,
  TrackReference
} from "./types";

export const SYNC_SCHEMA = "loud.sync.v1";

/// Shared auth token for token-protected servers (`LOUD_AUTH_TOKEN`).
/// API calls send it as a Bearer header; media and SSE URLs — which cannot
/// carry headers — embed it as an `access_token` query parameter that the
/// server accepts and never logs.
let syncAuthToken = "";

export function setSyncAuthToken(token: string): void {
  syncAuthToken = token.trim();
}

function authorizedFetch(
  fetcher: typeof fetch,
  url: string,
  init?: RequestInit
): ReturnType<typeof fetch> {
  if (!syncAuthToken) {
    return fetcher(url, init);
  }

  const headers = new Headers(init?.headers);
  headers.set("Authorization", `Bearer ${syncAuthToken}`);
  return fetcher(url, { ...init, headers });
}

function withAccessToken(url: string): string {
  if (!syncAuthToken) {
    return url;
  }

  const separator = url.includes("?") ? "&" : "?";
  return `${url}${separator}access_token=${encodeURIComponent(syncAuthToken)}`;
}

export interface SyncSnapshot {
  schema: typeof SYNC_SCHEMA;
  server_id: string;
  generated_at: number;
  library: MusicLibrary;
}

export interface SyncReport {
  tracks_upserted: number;
  playlists_upserted: number;
  sessions_upserted: number;
}

export interface RemotePlaybackSession<TSession = unknown> {
  device_id: string;
  saved_at: number;
  session: TSession;
  updated_at: number;
}

export interface PlaybackDevice {
  device_id: string;
  name: string;
  track_id: string | null;
  track_fingerprint: string | null;
  track_title: string | null;
  is_playing: boolean;
  position_seconds: number;
  volume: number;
  updated_at: number;
}

export interface ActivePlayback {
  device_id: string;
  track_id: string | null;
  track_fingerprint: string | null;
  track_title: string | null;
  is_playing: boolean;
  position_seconds: number;
  volume: number;
  updated_at: number;
}

export interface PlaybackTransfer {
  device_id: string;
  track_id?: string | null;
  track_fingerprint?: string | null;
  track_title?: string | null;
  is_playing: boolean;
  position_seconds: number;
  volume: number;
}

export interface PlaybackEvent {
  type: "active" | "device" | "devices";
  device?: PlaybackDevice;
  devices?: PlaybackDevice[];
  active?: ActivePlayback;
}

export type PlaybackStateKindV2 = "playing" | "paused" | "stopped";
export type PlaybackCommandKindV2 =
  | "play"
  | "pause"
  | "seek"
  | "load"
  | "next"
  | "previous"
  | "set_queue"
  | "set_shuffle"
  | "set_repeat"
  | "transfer"
  | "volume";

export interface PlaybackClockV2 {
  position_seconds: number;
  started_at_ms: number | null;
  stopped_at_ms: number | null;
  updated_at_ms: number;
}

export interface PlaybackContextV2 {
  playback_source: TrackReference[];
  playback_index: number;
  queued_tracks: TrackReference[];
  play_history: TrackReference[];
  shuffle: boolean;
  repeat: RepeatMode;
}

export interface PlaybackStateV2 {
  schema: "loud.playback.v2";
  revision: number;
  active_device_id: string | null;
  state: PlaybackStateKindV2;
  track: TrackReference | null;
  context: PlaybackContextV2;
  clock: PlaybackClockV2;
  volume: number;
  server_time_ms: number;
}

export interface PlaybackCommandV2 {
  command_id: string;
  kind: PlaybackCommandKindV2;
  device_id: string;
  target_device_id?: string | null;
  track?: TrackReference | null;
  context?: PlaybackContextV2 | null;
  position_seconds?: number;
  volume?: number;
  shuffle?: boolean;
  repeat?: RepeatMode;
}

export interface PlaybackEventV2 {
  type: "playback_state" | "device" | "devices";
  playback_state?: PlaybackStateV2;
  device?: PlaybackDevice;
  devices?: PlaybackDevice[];
}

export function normalizeServerUrl(value: string): string {
  const trimmed = value.trim().replace(/\/+$/, "");
  if (!trimmed) {
    return "";
  }

  if (/^https?:\/\//i.test(trimmed)) {
    return trimmed;
  }

  return `http://${trimmed}`;
}

export function trackAudioUrl(serverUrl: string, fingerprint: string): string {
  return withAccessToken(
    `${normalizeServerUrl(serverUrl)}/api/v1/tracks/${encodeURIComponent(fingerprint)}/audio`
  );
}

export function playbackEventsUrl(serverUrl: string): string {
  return withAccessToken(`${normalizeServerUrl(serverUrl)}/api/v1/playback/events`);
}

export function playbackEventsV2Url(serverUrl: string): string {
  return withAccessToken(`${normalizeServerUrl(serverUrl)}/api/v2/playback/events`);
}

function serverOrigin(serverUrl: string): string {
  try {
    return new URL(normalizeServerUrl(serverUrl)).origin;
  } catch {
    return normalizeServerUrl(serverUrl);
  }
}

function serverHost(serverUrl: string): string {
  try {
    return new URL(normalizeServerUrl(serverUrl)).hostname;
  } catch {
    return "<Mac IP>";
  }
}

function serverPort(serverUrl: string): string {
  try {
    return new URL(normalizeServerUrl(serverUrl)).port;
  } catch {
    return "";
  }
}

function syncApiError(action: string, serverUrl: string, response: Response): Error {
  if (response.status === 404) {
    const port = serverPort(serverUrl);
    const hint =
      port === "1420" || port === "5173"
        ? `${serverOrigin(serverUrl)} is the Codec web app dev server, not the sync server. Use http://${serverHost(
            serverUrl
          )}:8787 instead.`
        : `No Codec sync API answered at ${serverOrigin(
            serverUrl
          )}. Make sure this is the sync server address, usually http://${serverHost(serverUrl)}:8787.`;
    return new Error(`${action}. ${hint}`);
  }

  return new Error(`${action} (${response.status}).`);
}

export async function validateSyncServer(serverUrl: string, fetcher: typeof fetch = fetch): Promise<void> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/health`);
  if (!response.ok) {
    throw syncApiError("Could not reach Codec sync server", serverUrl, response);
  }
}

export async function fetchRemoteLibrary(serverUrl: string, fetcher: typeof fetch = fetch): Promise<MusicLibrary> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/library`);
  if (!response.ok) {
    throw syncApiError("Could not load sync library", serverUrl, response);
  }
  const library = (await response.json()) as Partial<MusicLibrary>;
  return normalizeLibrary(library);
}

export function normalizeLibrary(library: Partial<MusicLibrary>): MusicLibrary {
  const tracks = safeArray<Track>(library.tracks).map((track) => ({
    ...track,
    playlist_ids: safeArray(track.playlist_ids)
  }));
  const playlists = safeArray<Playlist>(library.playlists).map((playlist) => ({
    ...playlist,
    track_ids: safeArray(playlist.track_ids)
  }));
  const durationSeconds = tracks.reduce((sum, track) => sum + (track.duration_seconds ?? 0), 0);

  return {
    root_path: library.root_path ?? "loud://sync-server",
    scanned_at: Number(library.scanned_at) || Math.floor(Date.now() / 1000),
    stats: {
      trackCount: library.stats?.trackCount ?? tracks.length,
      playlistCount: library.stats?.playlistCount ?? playlists.filter((playlist) => !playlist.is_liked).length,
      likedCount: library.stats?.likedCount ?? tracks.filter((track) => track.is_liked).length,
      artistCount: library.stats?.artistCount ?? new Set(tracks.map((track) => track.artist)).size,
      albumCount: library.stats?.albumCount ?? new Set(tracks.map((track) => `${track.artist}|${track.album}`)).size,
      durationSeconds: library.stats?.durationSeconds ?? durationSeconds
    },
    artists: safeArray<ArtistSummary>(library.artists),
    albums: safeArray<AlbumSummary>(library.albums),
    playlists,
    tracks
  };
}

function safeArray<T>(value: T[] | null | undefined): T[] {
  return Array.isArray(value) ? value : [];
}

export async function pushLibrarySnapshot(
  serverUrl: string,
  deviceId: string,
  library: MusicLibrary,
  fetcher: typeof fetch = fetch
): Promise<SyncReport> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/sync/push`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      schema: SYNC_SCHEMA,
      device_id: deviceId,
      library
    })
  });

  if (!response.ok) {
    throw syncApiError("Could not push sync snapshot", serverUrl, response);
  }

  return response.json() as Promise<SyncReport>;
}

export async function saveRemotePlaybackSession<TSession>(
  serverUrl: string,
  deviceId: string,
  session: TSession,
  savedAt: number,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(fetcher, 
    `${normalizeServerUrl(serverUrl)}/api/v1/playback-session/${encodeURIComponent(deviceId)}`,
    {
      method: "PUT",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        device_id: deviceId,
        saved_at: savedAt,
        session
      })
    }
  );

  if (!response.ok) {
    throw syncApiError("Could not save playback session", serverUrl, response);
  }
}

export async function fetchLatestPlaybackSession<TSession>(
  serverUrl: string,
  fetcher: typeof fetch = fetch
): Promise<RemotePlaybackSession<TSession> | null> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/playback-session/latest`);
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw syncApiError("Could not load playback session", serverUrl, response);
  }
  return response.json() as Promise<RemotePlaybackSession<TSession>>;
}

export async function updatePlaybackDevice(
  serverUrl: string,
  device: PlaybackDevice,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(fetcher, 
    `${normalizeServerUrl(serverUrl)}/api/v1/playback/devices/${encodeURIComponent(device.device_id)}`,
    {
      method: "PUT",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(device)
    }
  );

  if (!response.ok) {
    throw syncApiError("Could not update playback device", serverUrl, response);
  }
}

export async function fetchPlaybackDevices(
  serverUrl: string,
  fetcher: typeof fetch = fetch
): Promise<PlaybackDevice[]> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/playback/devices`);
  if (!response.ok) {
    throw syncApiError("Could not load playback devices", serverUrl, response);
  }

  const devices = (await response.json()) as PlaybackDevice[] | null;
  return Array.isArray(devices) ? devices : [];
}

export async function fetchActivePlayback(
  serverUrl: string,
  fetcher: typeof fetch = fetch
): Promise<ActivePlayback | null> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/playback/active`);
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw syncApiError("Could not load active playback", serverUrl, response);
  }
  const active = (await response.json()) as ActivePlayback | null;
  return active ?? null;
}

export async function fetchPlaybackStateV2(
  serverUrl: string,
  fetcher: typeof fetch = fetch
): Promise<PlaybackStateV2 | null> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v2/playback`);
  if (!response.ok) {
    throw syncApiError("Could not load playback state", serverUrl, response);
  }
  const state = (await response.json()) as Partial<PlaybackStateV2> | null;
  return state ? normalizePlaybackStateV2(state) : null;
}

export async function sendPlaybackCommandV2(
  serverUrl: string,
  command: PlaybackCommandV2,
  fetcher: typeof fetch = fetch
): Promise<PlaybackStateV2> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v2/playback/commands`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify(command)
  });

  if (!response.ok) {
    throw syncApiError("Could not update playback", serverUrl, response);
  }
  return normalizePlaybackStateV2((await response.json()) as Partial<PlaybackStateV2>);
}

export function derivedPlaybackPosition(state: PlaybackStateV2, nowMs = Date.now(), clockOffsetMs = 0): number {
  const base = Math.max(0, Number(state.clock.position_seconds) || 0);
  if (state.state !== "playing" || !state.clock.started_at_ms) {
    return base;
  }

  const serverNowMs = nowMs + clockOffsetMs;
  return Math.max(0, base + Math.max(0, serverNowMs - state.clock.started_at_ms) / 1000);
}

export function normalizePlaybackStateV2(state: Partial<PlaybackStateV2>): PlaybackStateV2 {
  return {
    schema: "loud.playback.v2",
    revision: Number(state.revision) || 0,
    active_device_id:
      typeof state.active_device_id === "string" && state.active_device_id.trim()
        ? state.active_device_id
        : null,
    state:
      state.state === "playing" || state.state === "paused" || state.state === "stopped"
        ? state.state
        : "stopped",
    track: validTrackReference(state.track) ? state.track : null,
    context: normalizePlaybackContextV2(state.context),
    clock: {
      position_seconds: Math.max(0, Number(state.clock?.position_seconds) || 0),
      started_at_ms: nullableNumber(state.clock?.started_at_ms),
      stopped_at_ms: nullableNumber(state.clock?.stopped_at_ms),
      updated_at_ms: Number(state.clock?.updated_at_ms) || 0
    },
    volume: Math.max(0, Math.min(Number(state.volume) || 0, 1)),
    server_time_ms: Number(state.server_time_ms) || Date.now()
  };
}

export function normalizePlaybackContextV2(context: Partial<PlaybackContextV2> | null | undefined): PlaybackContextV2 {
  const playbackSource = safeArray<TrackReference>(context?.playback_source).filter(validTrackReference);
  return {
    playback_source: playbackSource,
    playback_index: clampIndex(Number(context?.playback_index) || 0, playbackSource.length),
    queued_tracks: safeArray<TrackReference>(context?.queued_tracks).filter(validTrackReference),
    play_history: safeArray<TrackReference>(context?.play_history).filter(validTrackReference),
    shuffle: Boolean(context?.shuffle),
    repeat:
      context?.repeat === "all" || context?.repeat === "one" || context?.repeat === "off"
        ? context.repeat
        : "off"
  };
}

function validTrackReference(value: unknown): value is TrackReference {
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

function nullableNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function clampIndex(index: number, length: number): number {
  if (length <= 0) {
    return 0;
  }
  return Math.max(0, Math.min(Math.trunc(index), length - 1));
}

export async function transferPlayback(
  serverUrl: string,
  transfer: PlaybackTransfer,
  fetcher: typeof fetch = fetch
): Promise<ActivePlayback> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/playback/transfer`, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify(transfer)
  });

  if (!response.ok) {
    throw syncApiError("Could not transfer playback", serverUrl, response);
  }
  return response.json() as Promise<ActivePlayback>;
}
