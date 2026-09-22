import { baseName, identityForImportTrack, IMPORT_SCHEMA, type ImportManifest, type ImportManifestTrack } from "./import";

export interface BundleEntry { path: string; file: File }

/** ZIP paths are relative, case-sensitive names, never URLs or filesystem paths. */
function relativePath(value: string): string {
  const slash = value.replace(/\\/g, "/");
  if (/^(\/|[a-zA-Z]:)/.test(slash) || slash.includes("\0")) throw new Error("Bundle paths must be relative.");
  const parts = slash.split("/").filter((part) => part && part !== ".");
  if (parts.includes("..")) throw new Error("Bundle paths cannot leave their folder.");
  if (!parts.length) throw new Error("A bundle file needs a name.");
  return parts.join("/");
}

async function readJSON(file: File): Promise<unknown> {
  if (file.size > 16 * 1024 * 1024) throw new Error(`${file.name} exceeds the 16 MiB manifest limit.`);
  try { return JSON.parse(await file.text()); }
  catch { throw new Error(`${file.name} is not valid JSON.`); }
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Keep folder paths intact. Flat multi-file selection may restore a referenced
 * path only when its basename identifies one selected file and one target path.
 * Artwork integrity/security validation remains centralized on the server. */
export async function prepareImportBundle(files: File[]): Promise<BundleEntry[]> {
  const entries = files.map((file) => ({ path: relativePath(file.webkitRelativePath || file.name), file }));
  const byPath = new Map<string, BundleEntry>();
  for (const entry of entries) {
    if (byPath.has(entry.path)) throw new Error(`Duplicate bundle path: ${entry.path}. Select the bundle folder instead.`);
    byPath.set(entry.path, entry);
  }
  let candidates: BundleEntry[] = [];
  for (const preferred of ["loud-import.json", "codec-import.json"]) {
    candidates = entries.filter((entry) => baseName(entry.path) === preferred);
    if (candidates.length) break;
  }
  if (!candidates.length) {
    for (const entry of entries.filter((entry) => entry.path.toLowerCase().endsWith(".json"))) {
      try {
        const value = await readJSON(entry.file);
        if (object(value) && value.schema === IMPORT_SCHEMA) candidates.push(entry);
      } catch { /* Unrelated JSON and invalid sidecars are not the main manifest. */ }
    }
  }
  if (candidates.length !== 1) {
    throw new Error(candidates.length ? "Multiple import manifests found. Select one bundle folder." : "Include loud-import.json or codec-import.json with the bundle files.");
  }
  const selected = candidates[0];
  const value = await readJSON(selected.file);
  if (!object(value) || (value.schema !== undefined && value.schema !== IMPORT_SCHEMA) || !Array.isArray(value.tracks) || (value.playlists !== undefined && !Array.isArray(value.playlists))) {
    throw new Error(`${selected.file.name} must be a ${IMPORT_SCHEMA} manifest with a tracks array.`);
  }
  const manifest = value as ImportManifest;
  const folder = selected.path.slice(0, selected.path.length - baseName(selected.path).length);
  const references = new Set<string>();
  const artworkTargets = new Set<string>();
  function reference(file: unknown, base: unknown) {
    if (typeof file !== "string" || (base !== undefined && base !== null && typeof base !== "string")) return;
    try {
      // Validate each part before joining so an absolute child never becomes relative.
      const child = relativePath(file);
      const basePath = typeof base === "string" && base && base !== "." ? relativePath(base) + "/" : "";
      references.add(relativePath(folder + basePath + child));
    } catch { /* The server reports invalid descriptors without discarding valid audio. */ }
  }
  function artwork(target: string, base: unknown, playlist: boolean, descriptor: unknown) {
    // Match the server's candidate selection before resolving filenames. A
    // present but invalid inline descriptor still wins: keep its raw JSON for
    // diagnostics instead of silently substituting a later sidecar image.
    if (descriptor === undefined || descriptor === null) return;
    const key = `${playlist ? "playlist" : "track"}:${target.trim()}`;
    if (artworkTargets.has(key)) return;
    artworkTargets.add(key);
    if (object(descriptor)) reference(descriptor.file, base);
  }
  for (const track of manifest.tracks ?? []) {
    if (!object(track)) continue;
    reference(track.file, manifest.source?.base_path);
    try { artwork(identityForImportTrack(track as ImportManifestTrack), manifest.source?.base_path, false, track.artwork); }
    catch { /* Invalid identity fields remain in the server-validated manifest. */ }
  }
  for (const playlist of manifest.playlists ?? []) {
    if (!object(playlist)) continue;
    artwork(typeof playlist.name === "string" ? playlist.name : "", manifest.source?.base_path, true, playlist.artwork);
    for (const ref of playlist.tracks ?? []) {
      if (typeof ref === "string" && /\.(mp3|m4a|flac|wav)$/i.test(ref)) reference(ref, manifest.source?.base_path);
      else if (object(ref)) reference(ref.file, manifest.source?.base_path);
    }
  }
  for (const [name, schema, key] of [
    ["track-artwork.json", "s2y.track-artwork.v1", "tracks"],
    ["playlist-artwork.json", "s2y.playlist-artwork.v1", "playlists"]
  ]) {
    const sidecar = byPath.get(folder + name);
    if (!sidecar) continue;
    try {
      const side = await readJSON(sidecar.file);
      if (object(side) && side.schema === schema && Array.isArray(side[key])) {
        for (const row of side[key]) {
          if (!object(row)) continue;
          const target = key === "playlists" ? row.name : row.fingerprint;
          if (typeof target === "string" && target.trim()) artwork(target, side.base_path, key === "playlists", row.artwork);
        }
      }
    } catch { /* Keep original JSON for the server's artwork warning report. */ }
  }

  const assigned = new Map<File, string>();
  for (const path of references) {
    const exact = byPath.get(path);
    const matching = exact ? [exact] : entries.filter((entry) => !entry.file.webkitRelativePath && entry.file.name === baseName(path));
    if (matching.length !== 1) continue; // Missing files remain explicit server diagnostics.
    const match = matching[0];
    const previous = assigned.get(match.file);
    if (previous && previous !== path) {
      throw new Error(`More than one bundle file is named ${match.file.name}. Select the bundle folder or its ZIP to preserve paths.`);
    }
    assigned.set(match.file, path);
  }
  return entries.map((entry) => ({ ...entry, path: assigned.get(entry.file) ?? entry.path }));
}

const crcTable = new Uint32Array(256);
for (let value = 0; value < 256; value++) {
  let crc = value;
  for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  crcTable[value] = crc >>> 0;
}

/** Always emit ZIP64: a normal S2Y bundle can exceed 4 GiB without any one
 * track being large. Header construction does not allocate the file's bytes. */
export function zip64EntryHeaders(path: string, size: number, crc: number, offset: number) {
  if (![size, offset].every((value) => Number.isSafeInteger(value) && value >= 0)) throw new Error("Bundle is too large for this browser.");
  const name = new TextEncoder().encode(relativePath(path));
  if (name.length > 65535) throw new Error("A bundle filename is too long.");
  const local = new Uint8Array(30 + name.length + 20);
  const l = new DataView(local.buffer);
  l.setUint32(0, 0x04034b50, true); l.setUint16(4, 45, true); l.setUint16(6, 0x800, true);
  l.setUint32(14, crc, true); l.setUint32(18, 0xffffffff, true); l.setUint32(22, 0xffffffff, true);
  l.setUint16(26, name.length, true); l.setUint16(28, 20, true); local.set(name, 30);
  const le = 30 + name.length;
  l.setUint16(le, 1, true); l.setUint16(le + 2, 16, true);
  l.setBigUint64(le + 4, BigInt(size), true); l.setBigUint64(le + 12, BigInt(size), true);
  const central = new Uint8Array(46 + name.length + 28);
  const c = new DataView(central.buffer);
  c.setUint32(0, 0x02014b50, true); c.setUint16(4, 45, true); c.setUint16(6, 45, true); c.setUint16(8, 0x800, true);
  c.setUint32(16, crc, true); c.setUint32(20, 0xffffffff, true); c.setUint32(24, 0xffffffff, true);
  c.setUint16(28, name.length, true); c.setUint16(30, 28, true); c.setUint32(42, 0xffffffff, true); central.set(name, 46);
  const ce = 46 + name.length;
  c.setUint16(ce, 1, true); c.setUint16(ce + 2, 24, true);
  c.setBigUint64(ce + 4, BigInt(size), true); c.setBigUint64(ce + 12, BigInt(size), true); c.setBigUint64(ce + 20, BigInt(offset), true);
  return { local, central };
}

export async function buildImportBundle(files: File[], onProgress: (fraction: number) => void = () => {}): Promise<Blob> {
  const entries = await prepareImportBundle(files);
  const total = entries.reduce((sum, entry) => sum + entry.file.size, 0);
  const parts: BlobPart[] = [];
  const directory: BlobPart[] = [];
  let directorySize = 0;
  let offset = 0, processed = 0, lastProgress = 0, sinceYield = 0;
  for (const entry of entries) {
    let crc = 0xffffffff;
    // Limit live working memory even for multi-gigabyte files. Blob/File parts
    // are retained as originals; no audio is recompressed or reserialized.
    for (let start = 0; start < entry.file.size; start += 256 * 1024) {
      const bytes = new Uint8Array(await entry.file.slice(start, start + 256 * 1024).arrayBuffer());
      for (const byte of bytes) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
      processed += bytes.length; sinceYield += bytes.length;
      if (Date.now() - lastProgress >= 100) { onProgress(total ? processed / total : 1); lastProgress = Date.now(); }
      if (sinceYield >= 4 * 1024 * 1024) { await new Promise((resolve) => setTimeout(resolve, 0)); sinceYield = 0; }
    }
    const headers = zip64EntryHeaders(entry.path, entry.file.size, (crc ^ 0xffffffff) >>> 0, offset);
    parts.push(headers.local, entry.file);
    directory.push(headers.central);
    directorySize += headers.central.length;
    offset += headers.local.length + entry.file.size;
  }
  const end = new Uint8Array(56 + 20 + 22);
  const e = new DataView(end.buffer);
  e.setUint32(0, 0x06064b50, true); e.setBigUint64(4, 44n, true); e.setUint16(12, 45, true); e.setUint16(14, 45, true);
  e.setBigUint64(24, BigInt(entries.length), true); e.setBigUint64(32, BigInt(entries.length), true);
  e.setBigUint64(40, BigInt(directorySize), true); e.setBigUint64(48, BigInt(offset), true);
  e.setUint32(56, 0x07064b50, true); e.setBigUint64(64, BigInt(offset + directorySize), true); e.setUint32(72, 1, true);
  e.setUint32(76, 0x06054b50, true); e.setUint16(84, 0xffff, true); e.setUint16(86, 0xffff, true);
  e.setUint32(88, 0xffffffff, true); e.setUint32(92, 0xffffffff, true);
  onProgress(1);
  return new Blob([...parts, ...directory, end], { type: "application/zip" });
}
