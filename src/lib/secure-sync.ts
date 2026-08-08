export const SECURE_SYNC_SCHEMA = "loud.sync.v3";

import type { Library as MusicLibrary } from "./types";
import type { PlaybackCommandV2, PlaybackStateV2 } from "./sync";
import type { PlaybackDevice } from "./sync";
import { normalizeLibrary, normalizePlaybackStateV2, normalizeServerUrl } from "./sync";

const DEVICE_DB_NAME = "loud-secure-sync";
const DEVICE_DB_VERSION = 1;
const DEVICE_STORE = "keys";
const PRIMARY_KEY = "primary";

export interface SecureSyncIdentity {
  deviceId: string;
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}

export interface DeviceEnrollmentPayload {
  device_id: string;
  name: string;
  platform: string;
  public_key_jwk: {
    kty: "EC";
    crv: "P-256";
    x: string;
    y: string;
  };
}

export interface SecureSyncSnapshot {
  schema: typeof SECURE_SYNC_SCHEMA;
  generated_at: number;
  library: MusicLibrary;
}

export interface SecureSyncReport {
  tracks_upserted: number;
  playlists_upserted: number;
}

export interface SecureEnrolledDevice {
  device_id: string;
  name: string;
  platform: string;
  created_at: number;
  updated_at?: number;
  revoked_at?: number | null;
}

export interface SecurePlaybackEventPayload {
  type: "playback_state" | "devices";
  playback_state?: PlaybackStateV2;
  devices?: PlaybackDevice[];
}

export type SecurePlaybackEventHandler = (event: SecurePlaybackEventPayload) => void | Promise<void>;

interface StoredDeviceKey {
  id: string;
  deviceId: string;
  privateKey: CryptoKey;
  publicKey: CryptoKey;
  createdAt: number;
}

export function cleanSecureDeviceId(deviceId: string): string {
  return deviceId
    .trim()
    .replace(/[^A-Za-z0-9._:-]/g, "_")
    .slice(0, 96);
}

export async function createSecureSyncIdentity(deviceId: string): Promise<SecureSyncIdentity> {
  const pair = await crypto.subtle.generateKey(
    {
      name: "ECDSA",
      namedCurve: "P-256"
    },
    false,
    ["sign", "verify"]
  );

  return {
    deviceId: cleanSecureDeviceId(deviceId),
    privateKey: pair.privateKey,
    publicKey: pair.publicKey
  };
}

export async function loadOrCreateSecureSyncIdentity(deviceId: string): Promise<SecureSyncIdentity> {
  if (typeof indexedDB === "undefined") {
    return createSecureSyncIdentity(deviceId);
  }

  const db = await openDeviceDatabase();
  const stored = await readStoredDeviceKey(db);
  const cleanedDeviceId = cleanSecureDeviceId(deviceId);
  if (stored) {
    return {
      deviceId: stored.deviceId || cleanedDeviceId,
      privateKey: stored.privateKey,
      publicKey: stored.publicKey
    };
  }

  const identity = await createSecureSyncIdentity(cleanedDeviceId);
  await writeStoredDeviceKey(db, {
    id: PRIMARY_KEY,
    deviceId: identity.deviceId,
    privateKey: identity.privateKey,
    publicKey: identity.publicKey,
    createdAt: Date.now()
  });
  return identity;
}

export async function publicKeyJwk(identity: SecureSyncIdentity): Promise<DeviceEnrollmentPayload["public_key_jwk"]> {
  const jwk = await crypto.subtle.exportKey("jwk", identity.publicKey);
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || !jwk.x || !jwk.y) {
    throw new Error("Device public key is not P-256.");
  }

  return {
    kty: "EC",
    crv: "P-256",
    x: jwk.x,
    y: jwk.y
  };
}

export async function deviceEnrollmentPayload(
  identity: SecureSyncIdentity,
  name: string,
  platform: string
): Promise<DeviceEnrollmentPayload> {
  return {
    device_id: identity.deviceId,
    name,
    platform,
    public_key_jwk: await publicKeyJwk(identity)
  };
}

export async function enrollSecureDevice(
  serverUrl: string,
  identity: SecureSyncIdentity,
  name: string,
  platform: string,
  fetcher: typeof fetch = fetch
): Promise<SecureEnrolledDevice> {
  const response = await fetcher(`${normalizeServerUrl(serverUrl)}/api/v3/devices`, {
    method: "POST",
    credentials: "include",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify(await deviceEnrollmentPayload(identity, name, platform))
  });

  if (!response.ok) {
    throw new Error(`Could not enroll secure device (${response.status}).`);
  }

  return response.json() as Promise<SecureEnrolledDevice>;
}

export async function signedRequest(
  identity: SecureSyncIdentity,
  input: RequestInfo | URL,
  init: RequestInit = {},
  nowMs = Date.now()
): Promise<Request> {
  const request = new Request(input, init);
  const body = await request.clone().arrayBuffer();
  const timestamp = Math.trunc(nowMs);
  const nonce = crypto.randomUUID ? crypto.randomUUID() : `${timestamp}-${Math.random().toString(16).slice(2)}`;
  const bodyHash = base64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", body)));
  const message = canonicalRequest(request.method, request.url, timestamp, nonce, bodyHash);
  const signature = await crypto.subtle.sign(
    {
      name: "ECDSA",
      hash: "SHA-256"
    },
    identity.privateKey,
    new TextEncoder().encode(message)
  );

  const headers = new Headers(request.headers);
  headers.set("x-loud-device-id", identity.deviceId);
  headers.set("x-loud-timestamp", String(timestamp));
  headers.set("x-loud-nonce", nonce);
  headers.set("x-loud-signature", base64Url(new Uint8Array(signature)));

  return new Request(request.url, {
    method: request.method,
    headers,
    body: request.method === "GET" || request.method === "HEAD" ? undefined : body,
    signal: request.signal
  });
}

export async function signedFetch(
  identity: SecureSyncIdentity,
  input: RequestInfo | URL,
  init: RequestInit = {},
  fetcher: typeof fetch = fetch
): Promise<Response> {
  return fetcher(await signedRequest(identity, input, init));
}

export async function validateSecureSyncServer(serverUrl: string, fetcher: typeof fetch = fetch): Promise<void> {
  const response = await fetcher(`${normalizeServerUrl(serverUrl)}/health`);
  if (!response.ok) {
    throw new Error(`Could not reach Loud sync server (${response.status}).`);
  }
}

export async function fetchSecureRemoteLibrary(
  serverUrl: string,
  identity: SecureSyncIdentity,
  fetcher: typeof fetch = fetch
): Promise<MusicLibrary> {
  const response = await signedFetch(identity, `${normalizeServerUrl(serverUrl)}/api/v3/library`, {}, fetcher);
  if (!response.ok) {
    throw new Error(`Could not load secure sync library (${response.status}).`);
  }

  const snapshot = (await response.json()) as Partial<SecureSyncSnapshot>;
  return normalizeLibrary(snapshot.library ?? {});
}

export async function pushSecureLibrarySnapshot(
  serverUrl: string,
  identity: SecureSyncIdentity,
  library: MusicLibrary,
  fetcher: typeof fetch = fetch
): Promise<SecureSyncReport> {
  const response = await signedFetch(
    identity,
    `${normalizeServerUrl(serverUrl)}/api/v3/sync/push`,
    {
      method: "PUT",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        schema: SECURE_SYNC_SCHEMA,
        library
      })
    },
    fetcher
  );

  if (!response.ok) {
    throw new Error(`Could not push secure sync library (${response.status}).`);
  }

  return response.json() as Promise<SecureSyncReport>;
}

export async function fetchSecurePlaybackState(
  serverUrl: string,
  identity: SecureSyncIdentity,
  fetcher: typeof fetch = fetch
): Promise<PlaybackStateV2 | null> {
  const response = await signedFetch(identity, `${normalizeServerUrl(serverUrl)}/api/v3/playback`, {}, fetcher);
  if (!response.ok) {
    throw new Error(`Could not load secure playback state (${response.status}).`);
  }

  const state = (await response.json()) as Partial<PlaybackStateV2> | null;
  return state ? normalizePlaybackStateV2(state) : null;
}

export async function sendSecurePlaybackCommand(
  serverUrl: string,
  identity: SecureSyncIdentity,
  command: PlaybackCommandV2,
  fetcher: typeof fetch = fetch
): Promise<PlaybackStateV2> {
  const response = await signedFetch(
    identity,
    `${normalizeServerUrl(serverUrl)}/api/v3/playback/commands`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(command)
    },
    fetcher
  );

  if (!response.ok) {
    throw new Error(`Could not update secure playback (${response.status}).`);
  }

  return normalizePlaybackStateV2((await response.json()) as Partial<PlaybackStateV2>);
}

export async function fetchSecureEnrolledDevices(
  serverUrl: string,
  identity: SecureSyncIdentity,
  fetcher: typeof fetch = fetch
): Promise<SecureEnrolledDevice[]> {
  const response = await signedFetch(identity, `${normalizeServerUrl(serverUrl)}/api/v3/devices`, {}, fetcher);
  if (!response.ok) {
    throw new Error(`Could not load secure devices (${response.status}).`);
  }

  const payload = (await response.json()) as { devices?: SecureEnrolledDevice[] | null };
  return Array.isArray(payload.devices) ? payload.devices : [];
}

export async function streamSecurePlaybackEvents(
  serverUrl: string,
  identity: SecureSyncIdentity,
  onEvent: SecurePlaybackEventHandler,
  options: { signal?: AbortSignal; fetcher?: typeof fetch } = {}
): Promise<void> {
  const response = await signedFetch(
    identity,
    `${normalizeServerUrl(serverUrl)}/api/v3/playback/events`,
    {
      headers: {
        Accept: "text/event-stream"
      },
      signal: options.signal
    },
    options.fetcher ?? fetch
  );

  if (!response.ok) {
    throw new Error(`Could not stream secure playback events (${response.status}).`);
  }
  if (!response.body) {
    throw new Error("Secure playback event stream had no body.");
  }

  await readServerSentEvents(response.body, async (eventName, data) => {
    if (!data.trim()) {
      return;
    }
    const parsed = JSON.parse(data);
    const payload = securePlaybackEventPayload(eventName, parsed);
    await onEvent(payload);
  });
}

function securePlaybackEventPayload(eventName: string, parsed: unknown): SecurePlaybackEventPayload {
  if (eventName === "playback_state") {
    const candidate = parsed as Partial<SecurePlaybackEventPayload>;
    return {
      type: "playback_state",
      playback_state: candidate.playback_state ?? normalizePlaybackStateV2(parsed as Partial<PlaybackStateV2>)
    };
  }
  if (eventName === "devices") {
    const candidate = parsed as Partial<SecurePlaybackEventPayload>;
    return {
      type: "devices",
      devices: Array.isArray(candidate.devices) ? candidate.devices : Array.isArray(parsed) ? parsed : []
    };
  }
  return parsed as SecurePlaybackEventPayload;
}

async function readServerSentEvents(
  stream: ReadableStream<Uint8Array>,
  onMessage: (eventName: string, data: string) => void | Promise<void>
): Promise<void> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let eventName = "message";
  let dataLines: string[] = [];

  while (true) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value ?? new Uint8Array(), { stream: !done });

    let lineEnd = buffer.search(/\r?\n/);
    while (lineEnd >= 0) {
      const rawLine = buffer.slice(0, lineEnd);
      const newlineLength = buffer[lineEnd] === "\r" && buffer[lineEnd + 1] === "\n" ? 2 : 1;
      buffer = buffer.slice(lineEnd + newlineLength);
      const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;

      if (!line) {
        if (dataLines.length > 0) {
          await onMessage(eventName, dataLines.join("\n"));
          eventName = "message";
          dataLines = [];
        }
      } else if (line.startsWith("event:")) {
        eventName = line.slice(6).trim();
      } else if (line.startsWith("data:")) {
        dataLines.push(line.slice(5).trimStart());
      }

      lineEnd = buffer.search(/\r?\n/);
    }

    if (done) {
      break;
    }
  }

  if (dataLines.length > 0) {
    await onMessage(eventName, dataLines.join("\n"));
  }
}

export function canonicalRequest(
  method: string,
  input: string | URL,
  timestamp: number,
  nonce: string,
  bodyHash: string
): string {
  const url = typeof input === "string" ? new URL(input) : input;
  return [
    method.toUpperCase(),
    url.pathname || "/",
    canonicalSearch(url),
    String(timestamp),
    nonce,
    bodyHash
  ].join("\n");
}

export function canonicalSearch(input: string | URL): string {
  const url = typeof input === "string" ? new URL(input) : input;
  const entries = [...url.searchParams.entries()].sort(([leftName, leftValue], [rightName, rightValue]) => {
    if (leftName === rightName) {
      return leftValue.localeCompare(rightValue);
    }
    return leftName.localeCompare(rightName);
  });

  if (entries.length === 0) {
    return "";
  }

  const params = new URLSearchParams();
  for (const [name, value] of entries) {
    params.append(name, value);
  }
  return `?${params.toString()}`;
}

export function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function openDeviceDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DEVICE_DB_NAME, DEVICE_DB_VERSION);
    request.onupgradeneeded = () => {
      request.result.createObjectStore(DEVICE_STORE, { keyPath: "id" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Could not open device key store."));
  });
}

function readStoredDeviceKey(db: IDBDatabase): Promise<StoredDeviceKey | null> {
  return new Promise((resolve, reject) => {
    const request = db.transaction(DEVICE_STORE, "readonly").objectStore(DEVICE_STORE).get(PRIMARY_KEY);
    request.onsuccess = () => resolve((request.result as StoredDeviceKey | undefined) ?? null);
    request.onerror = () => reject(request.error ?? new Error("Could not read device key."));
  });
}

function writeStoredDeviceKey(db: IDBDatabase, key: StoredDeviceKey): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = db.transaction(DEVICE_STORE, "readwrite").objectStore(DEVICE_STORE).put(key);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error ?? new Error("Could not save device key."));
  });
}
