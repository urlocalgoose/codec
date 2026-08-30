/** Browser-side MP3 import: parse ID3 tags and derive the same canonical
 * identity the desktop library uses, so web uploads land on the sync server
 * as first-class tracks (and dedupe against desktop imports). */

export interface ParsedTags {
  title?: string;
  artist?: string;
  album?: string;
  albumArtist?: string;
  genre?: string;
  year?: number;
  trackNumber?: number;
  artwork?: { mime: string; data: Uint8Array };
}

/** FNV-1a 64-bit, hex — must match `stable_id` in src-tauri/src/library/util.rs. */
export function fnv1a64(value: string): string {
  const PRIME = 0x100000001b3n;
  const MASK = 0xffffffffffffffffn;
  let hash = 0xcbf29ce484222325n;
  const bytes = new TextEncoder().encode(value);
  for (const byte of bytes) {
    hash ^= BigInt(byte);
    hash = (hash * PRIME) & MASK;
  }
  return hash.toString(16).padStart(16, "0");
}

/** Whitespace-collapsing lowercase, matching `normalize` in util.rs. */
export function normalizeIdentity(value: string): string {
  return value.split(/\s+/).filter(Boolean).join(" ").toLowerCase();
}

/** Matches `fingerprint_for` in util.rs: identity from normalized tags. */
export function fingerprintFor(title: string, artist: string, album: string): string {
  return fnv1a64(
    `${normalizeIdentity(title)}|${normalizeIdentity(artist)}|${normalizeIdentity(album)}`
  );
}

// ---------------------------------------------------------------------------
// loud.import.v1 manifests (docs/codec-import-v1.md)
// ---------------------------------------------------------------------------

export interface ImportIdentifiers {
  isrc?: string;
  musicbrainz_recording_id?: string;
  spotify_track_id?: string;
  spotify_album_id?: string;
  youtube_video_id?: string;
}

export interface ImportManifestTrack {
  file?: string;
  title?: string;
  artist?: string;
  album?: string;
  album_artist?: string;
  genre?: string;
  year?: number;
  track_number?: number;
  duration_ms?: number;
  liked?: boolean;
  playlists?: string[];
  fingerprint?: string;
  identifiers?: ImportIdentifiers;
  source_urls?: Record<string, string>;
}

export type ImportPlaylistRef =
  | string
  | { fingerprint?: string; identifiers?: ImportIdentifiers; file?: string };

export interface ImportManifest {
  schema?: string;
  tracks?: ImportManifestTrack[];
  playlists?: { name?: string; mode?: string; tracks?: ImportPlaylistRef[] }[];
}

export const IMPORT_SCHEMA = "loud.import.v1";

/** Identity precedence from docs/codec-import-v1.md, matching
 * `canonical_import_fingerprint` in src-tauri/src/library/import.rs:
 * explicit fingerprint, then isrc/mbid/spotify/youtube, then tag identity. */
export function identityForImportTrack(track: ImportManifestTrack): string {
  const explicit = track.fingerprint?.trim();
  if (explicit) {
    return explicit;
  }
  const identifier = primaryIdentifierIdentity(track.identifiers);
  if (identifier) {
    return identifier;
  }
  return fingerprintFor(track.title ?? "", track.artist ?? "", track.album ?? "");
}

export function primaryIdentifierIdentity(identifiers?: ImportIdentifiers): string | null {
  if (!identifiers) {
    return null;
  }
  const isrc = identifiers.isrc?.trim();
  if (isrc) {
    return `isrc:${isrc.toUpperCase()}`;
  }
  const mbid = identifiers.musicbrainz_recording_id?.trim();
  if (mbid) {
    return `mbid:${mbid}`;
  }
  const spotify = identifiers.spotify_track_id?.trim();
  if (spotify) {
    return `spotify:track:${spotify}`;
  }
  const youtube = identifiers.youtube_video_id?.trim();
  if (youtube) {
    return `youtube:${youtube}`;
  }
  return null;
}

export function identityForPlaylistRef(
  ref: ImportPlaylistRef,
  identityByFile: Map<string, string>
): string | null {
  if (typeof ref === "string") {
    return identityByFile.get(ref) ?? null;
  }
  const explicit = ref.fingerprint?.trim();
  if (explicit) {
    return explicit;
  }
  const identifier = primaryIdentifierIdentity(ref.identifiers);
  if (identifier) {
    return identifier;
  }
  return ref.file ? (identityByFile.get(ref.file) ?? null) : null;
}

export function baseName(path: string): string {
  const parts = path.split(/[\\/]/);
  return parts[parts.length - 1] ?? path;
}

/** Minimal ID3v2.3/2.4 + ID3v1 reader: the common text frames and APIC. */
export function parseId3(buffer: ArrayBufferLike): ParsedTags {
  const bytes = new Uint8Array(buffer);
  const tags: ParsedTags = {};

  if (bytes.length > 10 && bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33) {
    const version = bytes[3];
    const tagSize = syncSafe(bytes, 6);
    let offset = 10;
    if ((bytes[5] & 0x40) !== 0) {
      // Skip the extended header.
      offset += version === 4 ? syncSafe(bytes, 10) : readUint32(bytes, 10) + 4;
    }
    const end = Math.min(10 + tagSize, bytes.length);

    while (offset + 10 <= end) {
      const id = String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);
      if (!/^[A-Z0-9]{4}$/.test(id)) {
        break;
      }
      const frameSize = version === 4 ? syncSafe(bytes, offset + 4) : readUint32(bytes, offset + 4);
      if (frameSize <= 0 || offset + 10 + frameSize > end) {
        break;
      }
      const body = bytes.subarray(offset + 10, offset + 10 + frameSize);
      applyFrame(tags, id, body);
      offset += 10 + frameSize;
    }
  }

  // ID3v1 fallback for anything v2 didn't provide.
  if (bytes.length >= 128) {
    const tail = bytes.subarray(bytes.length - 128);
    if (tail[0] === 0x54 && tail[1] === 0x41 && tail[2] === 0x47) {
      tags.title ||= id3v1Field(tail.subarray(3, 33));
      tags.artist ||= id3v1Field(tail.subarray(33, 63));
      tags.album ||= id3v1Field(tail.subarray(63, 93));
      if (!tags.year) {
        const year = Number.parseInt(latin1(tail.subarray(93, 97)).trim(), 10);
        if (Number.isFinite(year)) {
          tags.year = year;
        }
      }
    }
  }

  return tags;
}

function applyFrame(tags: ParsedTags, id: string, body: Uint8Array) {
  if (id === "APIC") {
    const artwork = parseApic(body);
    if (artwork && !tags.artwork) {
      tags.artwork = artwork;
    }
    return;
  }

  const text = decodeTextFrame(body);
  if (!text) {
    return;
  }

  switch (id) {
    case "TIT2":
      tags.title ||= text;
      break;
    case "TPE1":
      tags.artist ||= text;
      break;
    case "TALB":
      tags.album ||= text;
      break;
    case "TPE2":
      tags.albumArtist ||= text;
      break;
    case "TCON":
      tags.genre ||= text.replace(/^\(\d+\)/, "").trim() || undefined;
      break;
    case "TRCK": {
      const track = Number.parseInt(text, 10);
      if (Number.isFinite(track) && !tags.trackNumber) {
        tags.trackNumber = track;
      }
      break;
    }
    case "TYER":
    case "TDRC": {
      const year = Number.parseInt(text.slice(0, 4), 10);
      if (Number.isFinite(year) && !tags.year) {
        tags.year = year;
      }
      break;
    }
  }
}

function decodeTextFrame(body: Uint8Array): string | undefined {
  if (body.length < 2) {
    return undefined;
  }
  const text = decodeText(body[0], body.subarray(1));
  const cleaned = text.replace(/\0+$/g, "").split("\0")[0].trim();
  return cleaned || undefined;
}

function decodeText(encoding: number, bytes: Uint8Array): string {
  try {
    switch (encoding) {
      case 1:
        return new TextDecoder("utf-16").decode(bytes);
      case 2:
        return new TextDecoder("utf-16be").decode(bytes);
      case 3:
        return new TextDecoder("utf-8").decode(bytes);
      default:
        return latin1(bytes);
    }
  } catch {
    return latin1(bytes);
  }
}

function parseApic(body: Uint8Array): { mime: string; data: Uint8Array } | null {
  if (body.length < 4) {
    return null;
  }
  const encoding = body[0];
  let offset = 1;
  let mimeEnd = offset;
  while (mimeEnd < body.length && body[mimeEnd] !== 0) {
    mimeEnd += 1;
  }
  const mime = latin1(body.subarray(offset, mimeEnd)) || "image/jpeg";
  offset = mimeEnd + 1;
  if (offset >= body.length) {
    return null;
  }
  offset += 1; // picture type byte
  // Description string, terminated per encoding.
  if (encoding === 1 || encoding === 2) {
    while (offset + 1 < body.length && !(body[offset] === 0 && body[offset + 1] === 0)) {
      offset += 2;
    }
    offset += 2;
  } else {
    while (offset < body.length && body[offset] !== 0) {
      offset += 1;
    }
    offset += 1;
  }
  if (offset >= body.length) {
    return null;
  }
  return { mime, data: body.slice(offset) };
}

function syncSafe(bytes: Uint8Array, offset: number): number {
  return (
    ((bytes[offset] & 0x7f) << 21) |
    ((bytes[offset + 1] & 0x7f) << 14) |
    ((bytes[offset + 2] & 0x7f) << 7) |
    (bytes[offset + 3] & 0x7f)
  );
}

function readUint32(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
}

function id3v1Field(bytes: Uint8Array): string | undefined {
  return latin1(bytes).replace(/\0/g, "").trim() || undefined;
}

function latin1(bytes: Uint8Array): string {
  let out = "";
  for (const byte of bytes) {
    out += String.fromCharCode(byte);
  }
  return out;
}
