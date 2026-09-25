import { withSyncReadTimeout } from "./sync-read";
import { artworkCache } from "./artwork-cache";
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

/// Shared auth token for token-protected servers (`CODEC_AUTH_TOKEN`).
/// API calls send it as a Bearer header; media and SSE URLs — which cannot
/// carry headers — prefer a short-lived stream token in the URL. Older
/// servers fall back to the shared token, and the server request log never
/// prints query strings.
let syncAuthToken = "";
let syncStreamToken = "";
let syncStreamTokenExpiresAtMs = 0;
let streamTokenServer = "";
let streamTokenRetryAtMs = 0;
let authGeneration = 0;
const importRequests = new Set<AbortController>();
let streamTokenRequest: Promise<void> | null = null;
interface PlaybackCommandQueue {
  server: string;
  device: string;
  tail: Promise<unknown>;
  pending: number;
  acknowledgedRevisions: Set<number>;
  controller: AbortController;
}
let playbackCommandGeneration = 0;
let playbackCommandQueue: PlaybackCommandQueue | null = null;
const remoteLibraries = new Map<string, { etag: string; raw: Partial<MusicLibrary>; library: MusicLibrary; urlToken: string }>();

const STREAM_TOKEN_REFRESH_MARGIN_MS = 60_000;

export function setSyncAuthToken(token: string): void {
  const nextToken = token.trim();
  if (syncAuthToken === nextToken) {
    return;
  }
  syncAuthToken = nextToken;
  artworkCache.clear();
  authGeneration++;
  for (const controller of importRequests) controller.abort();
  resetPlaybackCommandQueue();
  syncStreamToken = "";
  syncStreamTokenExpiresAtMs = 0;
  streamTokenServer = "";
  streamTokenRetryAtMs = 0;
  streamTokenRequest = null;
  remoteLibraries.clear();
}

async function authorizedFetch(
  fetcher: typeof fetch,
  url: string,
  init?: RequestInit
): ReturnType<typeof fetch> {
  const headers = new Headers(init?.headers);
  if (syncAuthToken) headers.set("Authorization", `Bearer ${syncAuthToken}`);
  try {
    return await fetcher(url, { ...init, headers });
  } catch (error) {
    if (error instanceof TypeError || (error instanceof Error && error.name === "NetworkError")) {
      const offline = typeof navigator !== "undefined" && navigator.onLine === false;
      throw new Error(offline
        ? "You're offline. Reconnect to reach your Codec server. Downloaded music is still available."
        : "Could not reach your Codec server. Check the server address or try again.");
    }
    throw error;
  }
}

function withAccessToken(url: string): string {
  const token = urlAccessToken();
  if (!token) {
    return url;
  }

  const parsed = new URL(url);
  parsed.searchParams.set("access_token", token);
  return parsed.toString();
}

function withArtworkAccessToken(url: string, serverUrl?: string): string {
  if (!serverUrl) return url;
  try {
    const server = new URL(`${normalizeServerUrl(serverUrl)}/`);
    const artwork = new URL(url, server);
    const prefix = server.pathname.replace(/\/$/, "");
    if (artwork.origin !== server.origin || !artwork.pathname.startsWith(`${prefix}/`)) return url;
    const endpoint = artwork.pathname.slice(prefix.length);
    // Library metadata may contain external/signed images. Only Codec's
    // own protected artwork endpoints receive Codec credentials.
    if (!/^\/api\/v1\/(tracks|playlists)\/[^/]+\/artwork$/.test(endpoint)) return url;
    return withAccessToken(artwork.href);
  } catch {
    return url;
  }
}

function urlAccessToken(): string {
  if (syncStreamToken && Date.now() + STREAM_TOKEN_REFRESH_MARGIN_MS < syncStreamTokenExpiresAtMs) {
    return syncStreamToken;
  }
  return syncAuthToken;
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

export interface StreamToken {
  token: string;
  expires_at: number;
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
  /** Explicit source playlist; never inferred from track membership. */
  playlist_id?: string | null;
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
  expectedRevision?: number;
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
  type: "playback_state" | "device" | "devices" | "library";
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

  // Scheme-less input: an https page can never call an http server (mixed
  // content is silently blocked), so inherit the page's scheme. Native and
  // dev contexts keep http for LAN servers.
  const secure = typeof location !== "undefined" && location.protocol === "https:";
  return `${secure ? "https" : "http"}://${trimmed}`;
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
  return withSyncReadTimeout(async (signal) => {
    const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/health`, { signal });
    if (!response.ok) {
      throw syncApiError("Could not reach Codec sync server", serverUrl, response);
    }
  });
}

export async function refreshSyncStreamToken(serverUrl: string, fetcher: typeof fetch = fetch): Promise<void> {
  if (!syncAuthToken) {
    return;
  }
  const server = normalizeServerUrl(serverUrl);
  if (streamTokenServer !== server) {
    streamTokenServer = server;
    syncStreamToken = "";
    syncStreamTokenExpiresAtMs = 0;
    streamTokenRetryAtMs = 0;
    streamTokenRequest = null;
  }
  if (Date.now() + STREAM_TOKEN_REFRESH_MARGIN_MS < syncStreamTokenExpiresAtMs || Date.now() < streamTokenRetryAtMs) {
    return;
  }
  if (streamTokenRequest) {
    return streamTokenRequest;
  }

  const generation = authGeneration;
  const request = withSyncReadTimeout(async (signal) => {
    const response = await authorizedFetch(fetcher, `${server}/api/v1/auth/stream-token`, { method: "POST", signal });
    if (generation !== authGeneration || server !== streamTokenServer) {
      return;
    }
    if (!response.ok) {
      streamTokenRetryAtMs = Date.now() + STREAM_TOKEN_REFRESH_MARGIN_MS;
      return;
    }
    const streamToken = (await response.json()) as Partial<StreamToken>;
    if (generation === authGeneration && server === streamTokenServer && typeof streamToken.token === "string" && Number(streamToken.expires_at) > 0) {
      syncStreamToken = streamToken.token;
      syncStreamTokenExpiresAtMs = Number(streamToken.expires_at) * 1000;
    }
  });
  streamTokenRequest = request;
  try {
    await request;
  } finally {
    if (streamTokenRequest === request) {
      streamTokenRequest = null;
    }
  }
}

export async function fetchRemoteLibrary(serverUrl: string, fetcher: typeof fetch = fetch): Promise<MusicLibrary> {
  const server = normalizeServerUrl(serverUrl);
  const generation = authGeneration;
  const cached = remoteLibraries.get(server);
  const response = await authorizedFetch(fetcher, `${server}/api/v1/library`, {
    headers: cached?.etag ? { "If-None-Match": cached.etag } : {}
  });
  if (generation !== authGeneration) {
    throw new Error("The server connection changed while loading the library.");
  }
  if (response.status === 304 && cached) {
    if (cached.urlToken !== urlAccessToken()) {
      cached.library = normalizeLibrary(cached.raw, server);
      cached.urlToken = urlAccessToken();
    }
    return cached.library;
  }
  if (!response.ok) {
    throw syncApiError("Could not load sync library", serverUrl, response);
  }
  const raw = (await response.json()) as Partial<MusicLibrary>;
  if (generation !== authGeneration) {
    throw new Error("The server connection changed while loading the library.");
  }
  const library = normalizeLibrary(raw, server);
  if (generation === authGeneration) {
    remoteLibraries.set(server, { etag: response.headers.get("ETag") ?? "", raw, library, urlToken: urlAccessToken() });
  }
  return library;
}

export function normalizeLibrary(library: Partial<MusicLibrary>, serverUrl?: string): MusicLibrary {
  const tracks = safeArray<Track>(library.tracks).map((track) => ({
    ...track,
    playlist_ids: safeArray(track.playlist_ids),
    artwork_url: track.artwork_url ? withArtworkAccessToken(track.artwork_url, serverUrl) : track.artwork_url
  }));
  const playlists = safeArray<Playlist>(library.playlists).map((playlist) => ({
    ...playlist,
    track_ids: safeArray(playlist.track_ids),
    artwork_url: playlist.artwork_url ? withArtworkAccessToken(playlist.artwork_url, serverUrl) : playlist.artwork_url
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

/** URL for the server's full-library export zip (loud.import.v1 manifest +
 * audio). Carries a URL token because downloads are plain navigations. */
export function libraryExportUrl(serverUrl: string): string {
  return withAccessToken(`${normalizeServerUrl(serverUrl)}/api/v1/export`);
}

export async function createRemotePlaylist(
  serverUrl: string,
  name: string,
  fetcher: typeof fetch = fetch
): Promise<Playlist> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/playlists`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ name })
  });

  if (!response.ok) {
    throw syncApiError("Could not create playlist", serverUrl, response);
  }
  return (await response.json()) as Playlist;
}

export async function addTrackToRemotePlaylist(
  serverUrl: string,
  playlistId: string,
  fingerprint: string,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(
    fetcher,
    `${normalizeServerUrl(serverUrl)}/api/v1/playlists/${encodeURIComponent(playlistId)}/tracks`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ fingerprint })
    }
  );

  if (!response.ok) {
    throw syncApiError("Could not add to playlist", serverUrl, response);
  }
}

/** Delete only the playlist container. Its tracks and media remain in the library. */
export async function deleteRemotePlaylist(
  serverUrl: string,
  playlistId: string,
  fetcher: typeof fetch = fetch
): Promise<void> {
  await withSyncReadTimeout(async signal => {
    const response = await authorizedFetch(fetcher,
      `${normalizeServerUrl(serverUrl)}/api/v1/playlists/${encodeURIComponent(playlistId)}`,
      { method: "DELETE", signal }
    );
    if (!response.ok) throw syncApiError("Could not delete playlist", serverUrl, response);
  });
}

export async function removeTrackFromRemotePlaylist(
  serverUrl: string,
  playlistId: string,
  fingerprint: string,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(fetcher,
    `${normalizeServerUrl(serverUrl)}/api/v1/playlists/${encodeURIComponent(playlistId)}/tracks/${encodeURIComponent(fingerprint)}`,
    { method: "DELETE" }
  );
  if (!response.ok) {
    throw syncApiError("Could not remove from playlist", serverUrl, response);
  }
}

export async function setRemotePlaylistTracks(serverUrl: string, playlistId: string, trackIds: string[], fetcher: typeof fetch = fetch): Promise<void> {
  const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/playlists/${encodeURIComponent(playlistId)}/tracks`, {
    method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ track_ids: trackIds })
  });
  if (!response.ok) throw syncApiError("Could not reorder playlist", serverUrl, response);
}

export async function renameRemotePlaylist(
  serverUrl: string,
  playlistId: string,
  name: string,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(fetcher,
    `${normalizeServerUrl(serverUrl)}/api/v1/playlists/${encodeURIComponent(playlistId)}/name`,
    {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name })
    }
  );
  if (!response.ok) {
    throw syncApiError("Could not rename playlist", serverUrl, response);
  }
}

export async function uploadTrackMetadata(
  serverUrl: string,
  track: Track,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(
    fetcher,
    `${normalizeServerUrl(serverUrl)}/api/v1/tracks/${encodeURIComponent(track.fingerprint)}`,
    {
      method: "PUT",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(track)
    }
  );

  if (!response.ok) {
    throw syncApiError("Could not import track metadata", serverUrl, response);
  }
}

export async function uploadTrackAudio(
  serverUrl: string,
  fingerprint: string,
  audio: Blob,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(
    fetcher,
    `${normalizeServerUrl(serverUrl)}/api/v1/tracks/${encodeURIComponent(fingerprint)}/audio`,
    {
      method: "PUT",
      headers: {
        "Content-Type": audio.type || "audio/mpeg"
      },
      body: audio
    }
  );

  if (!response.ok) {
    throw syncApiError("Could not upload audio", serverUrl, response);
  }
}

export async function uploadTrackArtwork(
  serverUrl: string,
  fingerprint: string,
  image: Blob,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(
    fetcher,
    `${normalizeServerUrl(serverUrl)}/api/v1/tracks/${encodeURIComponent(fingerprint)}/artwork`,
    {
      method: "PUT",
      headers: {
        "Content-Type": image.type || "image/jpeg"
      },
      body: image
    }
  );

  if (!response.ok) {
    throw syncApiError("Could not upload artwork", serverUrl, response);
  }
}

export async function uploadPlaylistArtwork(
  serverUrl: string,
  playlistId: string,
  image: Blob,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(
    fetcher,
    `${normalizeServerUrl(serverUrl)}/api/v1/playlists/${encodeURIComponent(playlistId)}/artwork`,
    {
      method: "PUT",
      headers: {
        "Content-Type": image.type || "image/jpeg"
      },
      body: image
    }
  );

  if (!response.ok) {
    throw syncApiError("Could not update playlist cover", serverUrl, response);
  }
}

export async function setTrackLiked(
  serverUrl: string,
  fingerprint: string,
  liked: boolean,
  fetcher: typeof fetch = fetch
): Promise<void> {
  const response = await authorizedFetch(fetcher, 
    `${normalizeServerUrl(serverUrl)}/api/v1/tracks/${encodeURIComponent(fingerprint)}/liked`,
    {
      method: "PUT",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ liked })
    }
  );

  if (!response.ok) {
    throw syncApiError("Could not update liked state", serverUrl, response);
  }
}

export async function fetchPlaybackDevices(
  serverUrl: string,
  fetcher: typeof fetch = fetch
): Promise<PlaybackDevice[]> {
  return withSyncReadTimeout(async (signal) => {
    const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v1/playback/devices`, { signal });
    if (!response.ok) {
      throw syncApiError("Could not load playback devices", serverUrl, response);
    }
    const devices = (await response.json()) as PlaybackDevice[] | null;
    return Array.isArray(devices) ? devices : [];
  });
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
  fetcher: typeof fetch = fetch,
  signal?: AbortSignal
): Promise<PlaybackStateV2 | null> {
  return withSyncReadTimeout(async (readSignal) => {
    const response = await authorizedFetch(fetcher, `${normalizeServerUrl(serverUrl)}/api/v2/playback`, { signal: readSignal });
    if (!response.ok) {
      throw syncApiError("Could not load playback state", serverUrl, response);
    }
    const state = (await response.json()) as Partial<PlaybackStateV2> | null;
    return state ? normalizePlaybackStateV2(state) : null;
  }, signal);
}

export async function sendPlaybackCommandV2(
  serverUrl: string,
  command: PlaybackCommandV2,
  fetcher: typeof fetch = fetch,
  timeoutMs?: number
): Promise<PlaybackStateV2> {
  const server = normalizeServerUrl(serverUrl);
  if (playbackCommandQueue && (playbackCommandQueue.server !== server || playbackCommandQueue.device !== command.device_id)) {
    resetPlaybackCommandQueue();
  }
  if (!playbackCommandQueue || playbackCommandQueue.pending === 0) {
    playbackCommandQueue = {
      server, device: command.device_id, tail: Promise.resolve(), pending: 0,
      acknowledgedRevisions: new Set(), controller: new AbortController()
    };
  }
  const queue = playbackCommandQueue;
  const generation = playbackCommandGeneration;
  const { expectedRevision, ...payload } = command;
  const body = JSON.stringify(payload);
  queue.pending++;
  const pending = queue.tail.then(async () => {
    if (generation !== playbackCommandGeneration) {
      throw new Error("The server connection changed before the command was sent.");
    }
    // Optimistic actions queued together share the last displayed revision.
    // Advance only over revisions produced by our own earlier commands in
    // this burst. Any revision from another device leaves a gap and still
    // conflicts at the server instead of overwriting that device's changes.
    let revision = expectedRevision;
    while (revision !== undefined && queue.acknowledgedRevisions.has(revision + 1)) revision++;
    // Bound headers and body, without retrying an uncertain write. Later
    // snapshots retain their revision guard; an explicit Pause still runs.
    const state = await withSyncReadTimeout(async signal => {
      const response = await authorizedFetch(fetcher, `${server}/api/v2/playback/commands`, {
        signal,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(revision === undefined ? {} : { "If-Match": `"${revision}"` })
        },
        body
      });
      if (response.status === 409) {
        throw new Error("Playback changed on another device. Try the action again.");
      }
      if (!response.ok) {
        throw syncApiError("Could not update playback", serverUrl, response);
      }
      return normalizePlaybackStateV2((await response.json()) as Partial<PlaybackStateV2>);
    }, queue.controller.signal, timeoutMs);
    if (generation !== playbackCommandGeneration) {
      throw new Error("The playback connection changed.");
    }
    // Bare next/previous mutate the queue on the server, outside the local
    // optimistic snapshot. Do not let a queued snapshot undo that mutation.
    if (payload.kind !== "next" && payload.kind !== "previous" && Number.isSafeInteger(state.revision) && state.revision > 0) {
      queue.acknowledgedRevisions.add(state.revision);
    }
    return state;
  }).finally(() => {
    queue.pending--;
  });
  queue.tail = pending.catch(() => undefined);
  return pending;
}

export function resetPlaybackCommandQueue(): void {
  playbackCommandQueue?.controller.abort();
  playbackCommandGeneration++;
  playbackCommandQueue = null;
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
    playlist_id: typeof context?.playlist_id === "string" ? context.playlist_id.trim() || null : null,
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

// ---------------------------------------------------------------------------
// Bundle import jobs (server-side .loud.zip processing)
// ---------------------------------------------------------------------------

export interface ImportJobStatus {
  id: string;
  state: "running" | "done" | "failed";
  error?: string;
  total: number;
  done: number;
  current?: string;
  added: number;
  existing: number;
  audio_restored?: number;
  skipped: number;
  playlist_adds: number;
  liked: number;
  track_artwork_imported?: number;
  playlist_artwork_imported?: number;
  artwork_imported?: number;
  artwork_already_present?: number;
  artwork_missing?: number;
  artwork_failed?: number;
  artwork_warnings?: string[];
}

const IMPORT_CHUNK_BYTES = 8 * 1024 * 1024;
const LEGACY_IMPORT_MAX_BYTES = 64 * 1024 * 1024;
const IMPORT_UPLOAD_IDLE_MS = 30_000;
const IMPORT_READ_TIMEOUT_MS = 15_000;

class ImportUploadError extends Error {
  constructor(message: string, readonly status = 0, readonly retryable = false) {
    super(message);
  }
}

function importCancelled(): DOMException {
  return new DOMException("Bundle import cancelled", "AbortError");
}

function importHTTPError(status: number): ImportUploadError {
  return new ImportUploadError(status === 413
    ? "This bundle exceeds the server or proxy upload limit. Use a smaller bundle or the server import command."
    : status === 401 || status === 403
      ? "Your server did not authorize this import. Check your connection and auth token."
      : `Could not upload bundle (${status})`, status,
  status === 408 || status === 409 || status === 429 || status >= 500);
}

/** Every request uses the connection that started the import. Changing accounts
 * aborts outstanding work instead of sending the new account's token to it. */
function importConnection(signal?: AbortSignal) {
  const controller = new AbortController();
  const generation = authGeneration;
  const token = syncAuthToken;
  const cancel = () => controller.abort(importCancelled());
  if (signal?.aborted) cancel();
  else signal?.addEventListener("abort", cancel, { once: true });
  importRequests.add(controller);
  return {
    controller,
    token,
    current: () => generation === authGeneration,
    check() {
      if (controller.signal.aborted || generation !== authGeneration) throw importCancelled();
    },
    dispose() {
      importRequests.delete(controller);
      signal?.removeEventListener("abort", cancel);
    }
  };
}

type ImportConnection = ReturnType<typeof importConnection>;

/** XHR can stream Blob slices without buffering the archive in JavaScript.
 * The inactivity clock resets only when bytes move, not on repeated events. */
function importXHR(
  connection: ImportConnection,
  method: string,
  url: string,
  body: Blob | string | null = null,
  contentType = "application/json",
  onProgress?: (loaded: number) => void,
  idleMs = IMPORT_UPLOAD_IDLE_MS
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    connection.check();
    const request = new XMLHttpRequest();
    let settled = false;
    let uploaded = 0;
    let received = 0;
    let timer: ReturnType<typeof setTimeout>;
    const finish = (error?: Error, value?: unknown) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      connection.controller.signal.removeEventListener("abort", cancel);
      request.onload = request.onerror = request.onabort = request.ontimeout = request.onprogress = null;
      request.upload.onprogress = null;
      if (error) reject(error);
      else resolve(value);
    };
    const fail = (error: Error) => {
      finish(error);
      request.abort();
    };
    const cancel = () => fail(importCancelled());
    const armTimeout = () => {
      clearTimeout(timer);
      timer = setTimeout(() => fail(new ImportUploadError(
        "The bundle upload stopped responding. Check your connection and try again.", 0, true
      )), idleMs);
    };
    request.open(method, url);
    if (connection.token) request.setRequestHeader("Authorization", `Bearer ${connection.token}`);
    if (body !== null) request.setRequestHeader("Content-Type", contentType);
    request.upload.onprogress = (event) => {
      if (event.loaded > uploaded) {
        uploaded = event.loaded;
        armTimeout();
        onProgress?.(uploaded);
      }
    };
    request.onprogress = (event) => {
      if (event.loaded > received) {
        received = event.loaded;
        armTimeout();
      }
    };
    request.onload = () => {
      if (!connection.current() || connection.controller.signal.aborted) {
        finish(importCancelled());
        return;
      }
      if (request.status < 200 || request.status >= 300) {
        finish(importHTTPError(request.status));
        return;
      }
      try {
        finish(undefined, request.status === 204 ? null : JSON.parse(request.responseText));
      } catch {
        finish(new ImportUploadError("Could not upload bundle (bad response)"));
      }
    };
    request.onerror = () => finish(new ImportUploadError("The bundle upload connection was interrupted. Try again.", 0, true));
    request.onabort = () => finish(importCancelled());
    request.ontimeout = () => finish(new ImportUploadError("The bundle upload stopped responding. Try again.", 0, true));
    connection.controller.signal.addEventListener("abort", cancel, { once: true });
    armTimeout();
    try {
      connection.check();
      request.send(body);
    } catch (error) {
      finish(error instanceof Error ? error : new ImportUploadError("Could not upload bundle"));
    }
  });
}

interface ImportUploadStatus {
  id: string;
  offset: number;
  size: number;
  chunk_size: number;
}

function importJobID(value: unknown): string {
  const id = value && typeof value === "object" ? (value as { id?: unknown }).id : undefined;
  if (typeof id !== "string" || !id.trim()) throw new ImportUploadError("Could not upload bundle (bad response)");
  return id;
}

function importUploadStatus(value: unknown, size: number, id?: string): ImportUploadStatus {
  const status = value as ImportUploadStatus | null;
  if (!status || typeof status.id !== "string" || !status.id.trim() || (id && status.id !== id)
    || status.size !== size || !Number.isSafeInteger(status.offset) || status.offset < 0 || status.offset > size
    || !Number.isSafeInteger(status.chunk_size) || status.chunk_size <= 0) {
    throw new ImportUploadError("Could not upload bundle (bad response)");
  }
  return status;
}

/** Upload archives in bounded requests so an ordinary proxy size limit does not
 * reject a multi-gigabyte library. Older servers retain the small-bundle path. */
export async function uploadBundle(
  serverUrl: string,
  bundle: Blob,
  onProgress: (fraction: number) => void,
  options: { signal?: AbortSignal } = {}
): Promise<string> {
  const connection = importConnection(options.signal);
  const base = `${normalizeServerUrl(serverUrl)}/api/v1/import`;
  let uploadId: string | undefined;
  let completed = false;
  let progress = 0;
  const report = (loaded: number) => {
    connection.check();
    const fraction = bundle.size ? Math.min(1, loaded / bundle.size) : 1;
    if (fraction > progress) { progress = fraction; onProgress(fraction); }
  };
  const legacy = async () => {
    const result = await importXHR(connection, "POST", `${base}/bundle`, bundle, "application/zip", report);
    report(bundle.size);
    return importJobID(result);
  };
  try {
    connection.check();
    if (bundle.size <= IMPORT_CHUNK_BYTES) return await legacy();
    let status: ImportUploadStatus;
    try {
      status = importUploadStatus(await importXHR(connection, "POST", `${base}/uploads`,
        JSON.stringify({ size: bundle.size })), bundle.size);
    } catch (error) {
      if (!(error instanceof ImportUploadError) || (error.status !== 404 && error.status !== 405)) throw error;
      if (bundle.size > LEGACY_IMPORT_MAX_BYTES) {
        throw new Error("Update your Codec server to import large bundles from the browser, or use the server import command.");
      }
      return await legacy();
    }
    uploadId = status.id;
    if (status.offset !== 0) throw new ImportUploadError("Could not start the bundle upload. Try again.");
    const uploadURL = `${base}/uploads/${encodeURIComponent(uploadId)}`;
    const confirmedStatus = async () => {
      for (let attempt = 0; ; attempt++) {
        try {
          return importUploadStatus(await importXHR(connection, "GET", uploadURL), bundle.size, uploadId);
        } catch (error) {
          if (!(error instanceof ImportUploadError) || !error.retryable || attempt >= 2) throw error;
        }
      }
    };
    while (status.offset < bundle.size) {
      const start = status.offset;
      const end = Math.min(bundle.size, start + Math.min(status.chunk_size, IMPORT_CHUNK_BYTES));
      for (let attempt = 0; ; attempt++) {
        try {
          status = importUploadStatus(await importXHR(connection, "PUT", `${uploadURL}?offset=${start}`,
            bundle.slice(start, end), "application/octet-stream", loaded => report(start + Math.min(loaded, end - start))),
          bundle.size, uploadId);
          if (status.offset !== end) throw new ImportUploadError("Could not confirm the uploaded bundle. Try again.");
          break;
        } catch (error) {
          if (!(error instanceof ImportUploadError) || !error.retryable || attempt >= 2) throw error;
          status = await confirmedStatus();
          if (status.offset === end) break; // Server saved the chunk; its reply was lost.
          if (status.offset !== start) throw new ImportUploadError("The bundle upload changed unexpectedly. Try again.");
        }
      }
      report(status.offset);
    }
    for (let attempt = 0; ; attempt++) {
      try {
        const id = importJobID(await importXHR(connection, "POST", `${uploadURL}/complete`));
        completed = true;
        return id;
      } catch (error) {
        if (!(error instanceof ImportUploadError) || !error.retryable || attempt >= 2) throw error;
        status = await confirmedStatus();
        if (status.offset !== bundle.size) throw new ImportUploadError("Could not confirm the uploaded bundle. Try again.");
        // Completion is idempotent: retrying returns the same job, never a second import.
      }
    }
  } finally {
    connection.dispose();
    if (uploadId && !completed && connection.current()) {
      // Best effort cleanup must not delay cancellation or reuse a changed login.
      const cleanup = importConnection();
      void importXHR(cleanup, "DELETE", `${base}/uploads/${encodeURIComponent(uploadId)}`,
        null, "application/json", undefined, 5_000).catch(() => {}).finally(() => cleanup.dispose());
    }
  }
}

export async function fetchImportJob(
  serverUrl: string,
  jobId: string,
  fetcher: typeof fetch = fetch,
  signal?: AbortSignal
): Promise<ImportJobStatus | null> {
  const connection = importConnection(signal);
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    connection.controller.abort();
  }, IMPORT_READ_TIMEOUT_MS);
  let cancelRead: () => void = () => {};
  const cancelled = new Promise<never>((_, reject) => {
    cancelRead = () => reject(timedOut
      ? new Error("Your server is taking too long to send import progress. Retrying…")
      : importCancelled());
    connection.controller.signal.addEventListener("abort", cancelRead, { once: true });
    if (connection.controller.signal.aborted) cancelRead();
  });
  try {
    return await Promise.race([cancelled, (async () => {
      connection.check();
      const headers = new Headers();
      if (connection.token) headers.set("Authorization", `Bearer ${connection.token}`);
      const response = await fetcher(
        `${normalizeServerUrl(serverUrl)}/api/v1/import/jobs/${encodeURIComponent(jobId)}`,
        { headers, signal: connection.controller.signal }
      );
      connection.check();
      if (response.status === 404) return null;
      if (!response.ok) throw syncApiError("Could not read import progress", serverUrl, response);
      const result = await response.json() as ImportJobStatus;
      connection.check();
      if (!result || result.id !== jobId || !["running", "done", "failed"].includes(result.state)
        || ![result.total, result.done, result.added, result.existing, result.skipped, result.playlist_adds, result.liked]
          .every(value => Number.isSafeInteger(value) && value >= 0)) {
        throw new Error("Could not read import progress (bad response)");
      }
      return result;
    })()]);
  } finally {
    clearTimeout(timer);
    connection.controller.signal.removeEventListener("abort", cancelRead);
    connection.dispose();
  }
}
