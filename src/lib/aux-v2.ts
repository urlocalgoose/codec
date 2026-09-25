/** Aux uses an independent connection. Never put its token in the owner login. */
export type AuxMode = "shared_speaker" | "listen_together";
export interface AuxTrack {
  fingerprint: string; title: string; artist: string; album: string;
  duration_seconds: number; media_url: string; artwork_url: string;
  [key: string]: unknown;
}
export interface AuxEntry { entry_id: string; participant_id: string; track: AuxTrack }
export interface AuxMember { participant_id: string; display_name: string; joined_at: number; expires_at: number }
export interface AuxState {
  schema: "codec.aux.v2"; session_id: string; mode: AuxMode; host_name: string;
  role: "host" | "guest"; participant_id: string; expires_at: number;
  revision: number; server_time_ms: number; anchor_time_ms: number; position_seconds: number;
  status: "playing" | "paused" | "stopped"; current: AuxEntry | null; queue: AuxEntry[];
  allow_saves: boolean; allow_contributions: boolean;
  host_device_id?: string; media_token?: string; members?: AuxMember[];
}
export interface AuxConnection {
  server: string; session_id: string; participant_id: string;
  token: string; role: "host" | "guest"; expires_at: number;
}
export interface AuxInvitation { server: string; secret: string }
export interface AuxInviteInfo { schema: string; host_name: string; mode: AuxMode; expires_at: number }
export interface AuxCreated { schema: string; session_id: string; invite_secret: string; invite_expires_at: number; state: AuxState }
export interface AuxJoined { schema: string; session_id: string; participant_id: string; participant_token: string; expires_at: number; state: AuxState }
export class AuxError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}
const STORAGE_KEY = "codec.aux.v2.connection";

export function auxOrigin(value: string): string {
  const url = new URL(value);
  if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error("Enter the address of a Codec server, without a token.");
  }
  // The API lives at the server origin; a pasted page path is not an API base.
  return url.origin;
}

export function auxInvitation(value: string, server?: string): AuxInvitation {
  const input = value.trim();
  if (/^https?:\/\//i.test(input)) {
    const url = new URL(input);
    const secret = new URLSearchParams(url.hash.slice(1)).get("aux");
    if (!secret) throw new Error("Ask the host for a new Aux invitation link.");
    return { server: auxOrigin(url.origin), secret };
  }
  if (!server || input.length < 24) throw new Error("Paste the full Aux invitation link. Old four-character codes need a new invitation.");
  return { server: auxOrigin(server), secret: input };
}

export function auxInviteLink(server: string, secret: string): string {
  return `${auxOrigin(server)}/#aux=${encodeURIComponent(secret)}`;
}

/** Only this session's own media endpoint may receive its credential. */
export function auxMediaURL(connection: AuxConnection, state: AuxState, value: string): string {
  if (!value) return "";
  const url = new URL(value, connection.server);
  const prefix = `/api/v2/aux/sessions/${encodeURIComponent(connection.session_id)}/tracks/`;
  if (url.origin !== auxOrigin(connection.server) || !url.pathname.startsWith(prefix) ||
      !/\/(audio|artwork)$/.test(url.pathname) || url.username || url.password) return "";
  const token = connection.role === "host" ? state.media_token : connection.token;
  if (!token) return "";
  url.search = "";
  url.hash = "";
  url.searchParams.set("access_token", token);
  return url.href;
}

export async function auxRequest<T>(server: string, path: string, token = "", body?: unknown, method?: string, signal?: AbortSignal): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  if (signal?.aborted) abort(); else signal?.addEventListener("abort", abort, { once: true });
  const timeout = setTimeout(abort, 12_000);
  try {
    const response = await fetch(`${auxOrigin(server)}${path}`, {
      method: method ?? (body === undefined ? "GET" : "POST"), signal: controller.signal,
      credentials: "omit", cache: "no-store", redirect: "error",
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    });
    if (!response.ok) {
      const fallback = response.status === 401 || response.status === 403 ? "Your access to this Aux session has ended."
        : response.status === 404 || response.status === 410 ? "This Aux session is no longer available. Ask the host for a new invitation."
        : response.status === 409 ? "The queue changed. Check the latest queue and try again."
        : response.status === 429 ? "Too many requests. Wait a moment and try again."
        : "Couldn't reach Aux. Check your connection and try again.";
      throw new AuxError(fallback, response.status);
    }
    return response.status === 204 ? undefined as T : await response.json() as T;
  } catch (error) {
    if (controller.signal.aborted && !signal?.aborted) throw new AuxError("Aux took too long to respond. Check your connection and try again.", 0);
    throw error;
  } finally { clearTimeout(timeout); signal?.removeEventListener("abort", abort); }
}

export const auxPath = (connection: Pick<AuxConnection, "session_id">) => `/api/v2/aux/sessions/${encodeURIComponent(connection.session_id)}`;
export function saveAuxConnection(connection: AuxConnection): void {
  // A host already has a personal saved login. Do not duplicate its secret.
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...connection, token: connection.role === "host" ? "" : connection.token })); } catch { /* Optional restoration. */ }
}
export function restoreAuxConnection(ownerServer: string, ownerToken: string): AuxConnection | null {
  try {
    const value = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "null") as AuxConnection | null;
    if (!value || !["host", "guest"].includes(value.role) || !value.session_id || !value.participant_id ||
        !Number.isFinite(value.expires_at) || value.expires_at * 1000 <= Date.now()) return null;
    value.server = auxOrigin(value.server);
    if (value.role === "host") {
      if (!ownerToken || auxOrigin(ownerServer) !== value.server) return null;
      value.token = ownerToken;
    }
    return typeof value.token === "string" && value.token ? value : null;
  } catch { return null; }
}
export function clearAuxConnection() { try { localStorage.removeItem(STORAGE_KEY); } catch { /* Optional storage. */ } }

export function auxPosition(state: AuxState, receivedAt: number, now = performance.now()): number {
  const position = state.position_seconds + (state.status === "playing" ? Math.max(0, now - receivedAt) / 1000 : 0);
  return state.current?.track.duration_seconds ? Math.min(state.current.track.duration_seconds, Math.max(0, position)) : Math.max(0, position);
}

export function auxCanListen(state: AuxState, deviceId: string): boolean {
  return state.mode === "listen_together" || (state.role === "host" && state.host_device_id === deviceId);
}

export function auxCanRemove(state: AuxState, entry: AuxEntry): boolean {
  return state.role === "host" || entry.participant_id === state.participant_id;
}
