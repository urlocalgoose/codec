import {
  canonicalRequest,
  cleanDeviceId,
  cleanFingerprint,
  httpError,
  parseJsonBody,
  sha256Base64Url,
  timestampIsFresh,
  verifyAccessJwt,
  verifyDeviceSignature
} from "./security.mjs";

const SYNC_SCHEMA = "loud.sync.v3";
const PLAYBACK_SCHEMA = "loud.playback.v2";

export default {
  async fetch(request, env, ctx) {
    try {
      if (request.method === "OPTIONS") {
        return corsResponse(request, env, new Response(null, { status: 204 }));
      }

      const url = new URL(request.url);
      const bodyBytes = await request.arrayBuffer();
      const route = routeRequest(url.pathname);

      if (request.method === "GET" && url.pathname === "/health") {
        return json(request, env, {
          ok: true,
          schema: SYNC_SCHEMA,
          playback_schema: PLAYBACK_SCHEMA
        });
      }

      if (request.method === "POST" && url.pathname === "/api/v3/devices") {
        const identity = await verifyAccessJwt(request, env);
        return json(request, env, await enrollDevice(env, identity, await parseJsonBody(bodyBytes)));
      }

      if (route?.section === "devices" && request.method === "GET" && route.id === null) {
        const device = await requireSignedDevice(request, env, bodyBytes);
        return json(request, env, await listDevices(env, device.owner_email));
      }

      if (route?.section === "devices" && request.method === "DELETE" && route.id) {
        await requireSignedDevice(request, env, bodyBytes);
        await revokeDevice(env, route.id);
        return empty(request, env);
      }

      if (request.method === "GET" && url.pathname === "/api/v3/library") {
        await requireSignedDevice(request, env, bodyBytes);
        return json(request, env, await librarySnapshot(env, url.origin));
      }

      if (request.method === "PUT" && url.pathname === "/api/v3/sync/push") {
        const device = await requireSignedDevice(request, env, bodyBytes);
        const payload = await parseJsonBody(bodyBytes);
        return json(request, env, await pushLibrary(env, device, payload));
      }

      if (route?.section === "tracks" && route.id && route.leaf === "audio") {
        const device = await requireSignedDevice(request, env, bodyBytes);
        if (request.method === "PUT") {
          return json(request, env, await putEncryptedMedia(env, device, route.id, "audio", bodyBytes));
        }
        if (request.method === "GET") {
          return getEncryptedMedia(request, env, route.id, "audio");
        }
      }

      if (route?.section === "tracks" && route.id && route.leaf === "artwork") {
        const device = await requireSignedDevice(request, env, bodyBytes);
        if (request.method === "PUT") {
          return json(request, env, await putEncryptedMedia(env, device, route.id, "artwork", bodyBytes));
        }
        if (request.method === "GET") {
          return getEncryptedMedia(request, env, route.id, "artwork");
        }
      }

      if (url.pathname === "/api/v3/playback" || url.pathname.startsWith("/api/v3/playback/")) {
        await requireSignedDevice(request, env, bodyBytes);
        return env.PLAYBACK_ROOM.get(env.PLAYBACK_ROOM.idFromName("global")).fetch(
          new Request(request.url, {
            method: request.method,
            headers: request.headers,
            body: bodyBytes.byteLength > 0 ? bodyBytes : undefined
          })
        );
      }

      throw httpError(404, "Not found.");
    } catch (error) {
      return errorResponse(request, env, error);
    }
  }
};

export class PlaybackRoom {
  constructor(state) {
    this.state = state;
    this.sessions = new Set();
  }

  async fetch(request) {
    const url = new URL(request.url);
    const bodyBytes = await request.arrayBuffer();
    const route = routeRequest(url.pathname);

    if (request.method === "GET" && url.pathname === "/api/v3/playback") {
      return Response.json(await this.currentState());
    }

    if (request.method === "GET" && url.pathname === "/api/v3/playback/devices") {
      return Response.json(await this.currentDevices());
    }

    if (request.method === "PUT" && route?.section === "playback" && route.id === "devices" && route.leaf) {
      const device = await this.upsertDevice(route.leaf, await parseJsonBody(bodyBytes));
      this.broadcast("devices", await this.currentDevices());
      return Response.json(device);
    }

    if (request.method === "POST" && url.pathname === "/api/v3/playback/commands") {
      const command = await parseJsonBody(bodyBytes);
      const next = await this.applyCommand(command);
      this.broadcast("playback_state", next);
      return Response.json(next);
    }

    if (request.method === "GET" && url.pathname === "/api/v3/playback/events") {
      return this.eventStream();
    }

    return Response.json({ error: "Not found." }, { status: 404 });
  }

  async currentState() {
    return (await this.state.storage.get("playback_state")) ?? emptyPlaybackState(Date.now());
  }

  async currentDevices() {
    const cutoff = Date.now() - 2 * 60 * 1000;
    const devices = (await this.state.storage.get("playback_devices")) ?? [];
    return devices
      .filter((device) => Number(device.updated_at) >= cutoff)
      .sort((left, right) => Number(right.updated_at) - Number(left.updated_at));
  }

  async upsertDevice(deviceID, payload) {
    const now = Date.now();
    const device = cleanPlaybackDevice(payload, deviceID, now);
    const devices = (await this.currentDevices()).filter((candidate) => candidate.device_id !== device.device_id);
    const next = [device, ...devices];
    await this.state.storage.put("playback_devices", next);
    return device;
  }

  async applyCommand(command) {
    const commandID = String(command.command_id ?? "").trim();
    if (!commandID) {
      throw httpError(400, "Playback command id is required.");
    }

    const stored = await this.state.storage.get(`command:${commandID}`);
    if (stored) {
      return stored;
    }

    const now = Date.now();
    const current = await this.currentState();
    const next = mutatePlaybackState(current, command, now);
    next.schema = PLAYBACK_SCHEMA;
    next.revision = (current.revision ?? 0) + 1;
    next.server_time_ms = now;
    next.clock.updated_at_ms = now;
    normalizePlaybackState(next);

    await this.state.storage.put("playback_state", next);
    await this.state.storage.put(`command:${commandID}`, next, { expirationTtl: 24 * 60 * 60 });
    return next;
  }

  async eventStream() {
    const stream = new TransformStream();
    const writer = stream.writable.getWriter();
    const session = { writer };
    this.sessions.add(session);

    writer.write(encodeSse("playback_state", await this.currentState()));
    writer.write(encodeSse("devices", await this.currentDevices()));
    const interval = setInterval(() => writer.write(new TextEncoder().encode(": keepalive\n\n")).catch(() => {}), 25000);
    const close = () => {
      clearInterval(interval);
      this.sessions.delete(session);
      writer.close().catch(() => {});
    };
    this.state.waitUntil?.(new Promise(() => {}));

    return new Response(stream.readable, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache, no-transform",
        Connection: "keep-alive"
      }
    });
  }

  broadcast(event, payload) {
    const encoded = encodeSse(event, payload);
    for (const session of Array.from(this.sessions)) {
      session.writer.write(encoded).catch(() => this.sessions.delete(session));
    }
  }
}

async function requireSignedDevice(request, env, bodyBytes) {
  const deviceID = cleanDeviceId(request.headers.get("x-loud-device-id"));
  const timestamp = request.headers.get("x-loud-timestamp");
  const nonce = String(request.headers.get("x-loud-nonce") ?? "").trim();
  const signature = String(request.headers.get("x-loud-signature") ?? "").trim();
  if (!deviceID || !timestamp || !nonce || !signature) {
    throw httpError(401, "Signed device request headers are required.");
  }
  if (!timestampIsFresh(timestamp)) {
    throw httpError(401, "Signed request timestamp is outside the allowed window.");
  }

  const row = await env.DB.prepare(
    `SELECT device_id, owner_email, public_key_jwk, revoked_at FROM devices WHERE device_id = ?`
  ).bind(deviceID).first();
  if (!row || row.revoked_at) {
    throw httpError(401, "Device is not enrolled.");
  }

  const expiresAt = Date.now() + 5 * 60 * 1000;
  try {
    await env.DB.prepare(`INSERT INTO device_nonces(device_id, nonce, expires_at) VALUES (?, ?, ?)`)
      .bind(deviceID, nonce, expiresAt)
      .run();
  } catch {
    throw httpError(401, "Signed request nonce was already used.");
  }

  const url = new URL(request.url);
  const bodyHash = await sha256Base64Url(bodyBytes);
  const message = canonicalRequest({
    method: request.method,
    url,
    timestamp,
    nonce,
    bodyHash
  });
  const ok = await verifyDeviceSignature({
    publicKeyJwk: JSON.parse(row.public_key_jwk),
    signature,
    message
  });
  if (!ok) {
    throw httpError(401, "Signed request signature is invalid.");
  }

  return {
    device_id: row.device_id,
    owner_email: row.owner_email
  };
}

async function enrollDevice(env, identity, payload) {
  const deviceID = cleanDeviceId(payload.device_id);
  const name = String(payload.name ?? "").trim().slice(0, 120) || "Loud device";
  const platform = String(payload.platform ?? "").trim().slice(0, 40) || "unknown";
  const publicKeyJwk = payload.public_key_jwk;
  if (!deviceID) {
    throw httpError(400, "Device id is required.");
  }
  if (!publicKeyJwk || publicKeyJwk.kty !== "EC" || publicKeyJwk.crv !== "P-256") {
    throw httpError(400, "A P-256 public key JWK is required.");
  }

  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO devices(device_id, owner_email, name, platform, public_key_jwk, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET
       owner_email = excluded.owner_email,
       name = excluded.name,
       platform = excluded.platform,
       public_key_jwk = excluded.public_key_jwk,
       revoked_at = NULL,
       updated_at = excluded.updated_at`
  ).bind(deviceID, identity.email, name, platform, JSON.stringify(publicKeyJwk), now, now).run();

  return {
    device_id: deviceID,
    name,
    platform,
    owner_email: identity.email,
    created_at: now
  };
}

async function listDevices(env, ownerEmail) {
  const result = await env.DB.prepare(
    `SELECT device_id, name, platform, created_at, updated_at, revoked_at
     FROM devices
     WHERE owner_email = ?
     ORDER BY updated_at DESC`
  ).bind(ownerEmail).all();
  return { devices: result.results ?? [] };
}

async function revokeDevice(env, deviceID) {
  await env.DB.prepare(`UPDATE devices SET revoked_at = ?, updated_at = ? WHERE device_id = ?`)
    .bind(Date.now(), Date.now(), cleanDeviceId(deviceID))
    .run();
}

async function librarySnapshot(env, origin) {
  const tracks = await env.DB.prepare(`SELECT metadata_json, audio_key, artwork_key, updated_at FROM tracks ORDER BY updated_at DESC`).all();
  const playlists = await env.DB.prepare(`SELECT id, name, track_ids_json, updated_at FROM playlists ORDER BY name`).all();
  const normalizedTracks = (tracks.results ?? []).map((row) => {
    const track = JSON.parse(row.metadata_json);
    if (row.audio_key) {
      track.audio_url = `${origin}/api/v3/tracks/${encodeURIComponent(track.fingerprint)}/audio`;
    }
    if (row.artwork_key) {
      track.artwork_url = `${origin}/api/v3/tracks/${encodeURIComponent(track.fingerprint)}/artwork`;
    }
    track.updated_at = row.updated_at;
    return track;
  });
  const normalizedPlaylists = (playlists.results ?? []).map((row) => ({
    id: row.id,
    name: row.name,
    path: `loud://playlist/${row.id}`,
    track_ids: JSON.parse(row.track_ids_json || "[]"),
    is_liked: row.id === "liked",
    updated_at: row.updated_at
  }));

  return {
    schema: SYNC_SCHEMA,
    generated_at: Date.now(),
    library: {
      root_path: "loud://cloudflare",
      scanned_at: Math.floor(Date.now() / 1000),
      stats: summarizeLibrary(normalizedTracks, normalizedPlaylists),
      artists: [],
      albums: [],
      playlists: normalizedPlaylists,
      tracks: normalizedTracks
    }
  };
}

async function pushLibrary(env, device, payload) {
  if (payload.schema && payload.schema !== SYNC_SCHEMA && payload.schema !== "loud.sync.v1") {
    throw httpError(400, "Unsupported sync schema.");
  }
  const library = payload.library ?? {};
  const now = Date.now();
  let tracksUpserted = 0;
  let playlistsUpserted = 0;

  for (const track of Array.isArray(library.tracks) ? library.tracks : []) {
    const fingerprint = cleanFingerprint(track.fingerprint);
    if (!fingerprint) continue;
    track.fingerprint = fingerprint;
    await env.DB.prepare(
      `INSERT INTO tracks(fingerprint, metadata_json, owner_device_id, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(fingerprint) DO UPDATE SET
         metadata_json = excluded.metadata_json,
         owner_device_id = excluded.owner_device_id,
         updated_at = excluded.updated_at`
    ).bind(fingerprint, JSON.stringify(track), device.device_id, now).run();
    tracksUpserted += 1;
  }

  for (const playlist of Array.isArray(library.playlists) ? library.playlists : []) {
    const id = cleanDeviceId(playlist.id);
    if (!id) continue;
    await env.DB.prepare(
      `INSERT INTO playlists(id, name, track_ids_json, owner_device_id, updated_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name,
         track_ids_json = excluded.track_ids_json,
         owner_device_id = excluded.owner_device_id,
         updated_at = excluded.updated_at`
    ).bind(
      id,
      String(playlist.name ?? id).slice(0, 160),
      JSON.stringify(Array.isArray(playlist.track_ids) ? playlist.track_ids : []),
      device.device_id,
      now
    ).run();
    playlistsUpserted += 1;
  }

  return {
    tracks_upserted: tracksUpserted,
    playlists_upserted: playlistsUpserted
  };
}

async function putEncryptedMedia(env, device, fingerprint, kind, bodyBytes) {
  const clean = cleanFingerprint(fingerprint);
  if (!clean) {
    throw httpError(400, "Track fingerprint is required.");
  }
  if (bodyBytes.byteLength === 0) {
    throw httpError(400, "Encrypted media body is empty.");
  }
  const key = `tracks/${clean}/${kind}.enc`;
  await env.MEDIA_BUCKET.put(key, bodyBytes, {
    httpMetadata: {
      contentType: "application/octet-stream"
    },
    customMetadata: {
      device_id: device.device_id,
      encrypted: "client-side"
    }
  });

  const column = kind === "audio" ? "audio_key" : "artwork_key";
  await env.DB.prepare(`UPDATE tracks SET ${column} = ?, updated_at = ? WHERE fingerprint = ?`)
    .bind(key, Date.now(), clean)
    .run();

  return {
    fingerprint: clean,
    kind,
    size_bytes: bodyBytes.byteLength
  };
}

async function getEncryptedMedia(request, env, fingerprint, kind) {
  const key = `tracks/${cleanFingerprint(fingerprint)}/${kind}.enc`;
  const object = await env.MEDIA_BUCKET.get(key);
  if (!object) {
    throw httpError(404, "Encrypted media was not found.");
  }
  return corsResponse(request, env, new Response(object.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(object.size ?? ""),
      "Cache-Control": "private, max-age=31536000, immutable"
    }
  }));
}

function mutatePlaybackState(current, command, now) {
  const next = structuredClone(current ?? emptyPlaybackState(now));
  const kind = String(command.kind ?? "");
  const targetDevice = command.target_device_id || command.device_id || next.active_device_id;
  const position = playbackPositionAt(next, now);

  if (kind === "play") {
    if (command.track) next.track = command.track;
    if (command.context) next.context = cleanPlaybackContext(command.context);
    next.active_device_id = targetDevice;
    next.state = "playing";
    setClock(next, command.position_seconds ?? position, now, true);
    return next;
  }
  if (kind === "pause") {
    next.active_device_id = targetDevice;
    next.state = "paused";
    setClock(next, position, now, false);
    return next;
  }
  if (kind === "seek") {
    setClock(next, command.position_seconds ?? 0, now, next.state === "playing");
    return next;
  }
  if (kind === "load") {
    next.track = command.track ?? null;
    if (command.context) next.context = cleanPlaybackContext(command.context);
    next.active_device_id = targetDevice;
    next.state = command.track ? "paused" : "stopped";
    setClock(next, command.position_seconds ?? 0, now, false);
    return next;
  }
  if (kind === "next") {
    advanceNext(next, now);
    return next;
  }
  if (kind === "previous") {
    if (position > 3) {
      setClock(next, 0, now, next.state === "playing");
    } else {
      next.context.playback_index = Math.max(0, next.context.playback_index - 1);
      next.track = next.context.playback_source[next.context.playback_index] ?? next.track;
      setClock(next, 0, now, next.state === "playing");
    }
    return next;
  }
  if (kind === "set_queue") {
    if (!command.context) throw httpError(400, "set_queue needs context.");
    next.context = cleanPlaybackContext(command.context);
    return next;
  }
  if (kind === "set_shuffle") {
    next.context.shuffle = Boolean(command.shuffle);
    return next;
  }
  if (kind === "set_repeat") {
    next.context.repeat = ["off", "all", "one"].includes(command.repeat) ? command.repeat : "off";
    return next;
  }
  if (kind === "transfer") {
    next.active_device_id = targetDevice;
    setClock(next, command.position_seconds ?? position, now, next.state === "playing");
    return next;
  }
  if (kind === "volume") {
    next.volume = clamp(Number(command.volume ?? next.volume), 0, 1);
    return next;
  }
  throw httpError(400, `Unsupported playback command "${kind}".`);
}

function advanceNext(state, now) {
  if (state.context.repeat === "one" && state.track) {
    setClock(state, 0, now, state.state === "playing");
    return;
  }
  if (state.context.queued_tracks.length > 0) {
    if (state.track) state.context.play_history.push(state.track);
    state.track = state.context.queued_tracks.shift();
    setClock(state, 0, now, state.state === "playing");
    return;
  }
  const nextIndex = state.context.playback_index + 1;
  if (nextIndex < state.context.playback_source.length) {
    if (state.track) state.context.play_history.push(state.track);
    state.context.playback_index = nextIndex;
    state.track = state.context.playback_source[nextIndex];
    setClock(state, 0, now, state.state === "playing");
    return;
  }
  if (state.context.repeat === "all" && state.context.playback_source.length > 0) {
    state.context.playback_index = 0;
    state.track = state.context.playback_source[0];
    setClock(state, 0, now, state.state === "playing");
    return;
  }
  state.state = "stopped";
  setClock(state, 0, now, false);
}

function playbackPositionAt(state, now) {
  if (state.state !== "playing" || !state.clock.started_at_ms) {
    return Number(state.clock.position_seconds) || 0;
  }
  return Math.max(0, Number(state.clock.position_seconds) + (now - state.clock.started_at_ms) / 1000);
}

function setClock(state, position, now, playing) {
  state.clock = {
    position_seconds: Math.max(0, Number(position) || 0),
    started_at_ms: playing ? now : null,
    stopped_at_ms: playing ? null : now,
    updated_at_ms: now
  };
}

function emptyPlaybackState(now) {
  return {
    schema: PLAYBACK_SCHEMA,
    revision: 0,
    active_device_id: null,
    state: "stopped",
    track: null,
    context: {
      playback_source: [],
      playback_index: 0,
      queued_tracks: [],
      play_history: [],
      shuffle: false,
      repeat: "off"
    },
    clock: {
      position_seconds: 0,
      started_at_ms: null,
      stopped_at_ms: now,
      updated_at_ms: now
    },
    volume: 0.75,
    server_time_ms: now
  };
}

function normalizePlaybackState(state) {
  state.context = cleanPlaybackContext(state.context);
  state.volume = clamp(Number(state.volume ?? 0.75), 0, 1);
  if (!["playing", "paused", "stopped"].includes(state.state)) {
    state.state = "stopped";
  }
}

function cleanPlaybackContext(context) {
  return {
    playback_source: cleanTrackReferences(context?.playback_source),
    playback_index: Math.max(0, Number(context?.playback_index) || 0),
    queued_tracks: cleanTrackReferences(context?.queued_tracks),
    play_history: cleanTrackReferences(context?.play_history),
    shuffle: Boolean(context?.shuffle),
    repeat: ["off", "all", "one"].includes(context?.repeat) ? context.repeat : "off"
  };
}

function cleanTrackReferences(values) {
  return (Array.isArray(values) ? values : [])
    .map((track) => ({
      id: String(track?.id ?? "").trim(),
      path: String(track?.path ?? "").trim(),
      fingerprint: cleanFingerprint(track?.fingerprint)
    }))
    .filter((track) => track.id && track.fingerprint);
}

function cleanPlaybackDevice(payload, deviceID, now) {
  const cleanID = cleanDeviceId(payload?.device_id || deviceID);
  if (!cleanID) {
    throw httpError(400, "Playback device id is required.");
  }

  return {
    device_id: cleanID,
    name: String(payload?.name ?? "Unknown device").trim().slice(0, 80) || "Unknown device",
    track_id: nullableString(payload?.track_id),
    track_fingerprint: nullableString(payload?.track_fingerprint),
    track_title: nullableString(payload?.track_title),
    is_playing: Boolean(payload?.is_playing),
    position_seconds: Math.max(0, Number(payload?.position_seconds) || 0),
    volume: clamp(Number(payload?.volume ?? 0.75), 0, 1),
    updated_at: now
  };
}

function nullableString(value) {
  const clean = String(value ?? "").trim();
  return clean ? clean.slice(0, 240) : null;
}

function summarizeLibrary(tracks, playlists) {
  return {
    trackCount: tracks.length,
    playlistCount: playlists.filter((playlist) => !playlist.is_liked).length,
    likedCount: tracks.filter((track) => track.is_liked).length,
    artistCount: new Set(tracks.map((track) => track.artist).filter(Boolean)).size,
    albumCount: new Set(tracks.map((track) => `${track.artist}|${track.album}`).filter(Boolean)).size,
    durationSeconds: tracks.reduce((sum, track) => sum + Number(track.duration_seconds ?? 0), 0)
  };
}

function routeRequest(pathname) {
  const parts = pathname.split("/").filter(Boolean);
  if (parts[0] !== "api" || parts[1] !== "v3") return null;
  return {
    section: parts[2] ?? null,
    id: parts[3] ? decodeURIComponent(parts[3]) : null,
    leaf: parts[4] ?? null
  };
}

function encodeSse(event, payload) {
  const data = event === "playback_state"
    ? { type: event, playback_state: payload }
    : event === "devices"
      ? { type: event, devices: payload }
      : { type: event, [event]: payload };
  return new TextEncoder().encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function clamp(value, min, max) {
  if (!Number.isFinite(value)) return min;
  return Math.min(max, Math.max(min, value));
}

function json(request, env, value, status = 200) {
  return corsResponse(request, env, Response.json(value, { status }));
}

function empty(request, env) {
  return corsResponse(request, env, new Response(null, { status: 204 }));
}

function errorResponse(request, env, error) {
  const status = Number(error?.status) || 500;
  return json(request, env, { error: error?.message ?? "Unexpected server error." }, status);
}

function corsResponse(request, env, response) {
  const origin = request.headers.get("Origin");
  const allowed = String(env.ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  if (origin && (allowed.includes(origin) || allowed.includes("*"))) {
    response.headers.set("Access-Control-Allow-Origin", allowed.includes("*") ? "*" : origin);
    response.headers.set("Vary", "Origin");
  }
  response.headers.set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS");
  response.headers.set(
    "Access-Control-Allow-Headers",
    "Content-Type,x-loud-device-id,x-loud-timestamp,x-loud-nonce,x-loud-signature,Cf-Access-Jwt-Assertion"
  );
  return response;
}
