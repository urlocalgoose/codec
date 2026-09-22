import { describe, expect, test } from "bun:test";
import { buildImportBundle, prepareImportBundle, zip64EntryHeaders } from "./import-bundle";
import { artworkImportSummary, bundleImportSummary, syncTransferSummary, type ImportArtwork } from "./import";

const descriptor: ImportArtwork = {
  file: "artwork/cover.png", sha256: "a".repeat(64), mime_type: "image/png", width: 640, height: 640,
  source_url: "https://example.invalid/provenance-only", provenance: { provider: "s2y" }
};
function json(name: string, value: unknown): File { return new File([JSON.stringify(value)], name, { type: "application/json" }); }
function nested(file: File, path: string): File { Object.defineProperty(file, "webkitRelativePath", { value: path }); return file; }

describe("artwork bundle selection", () => {
  test("canonical filenames use the same exact case as the server", async () => {
    const upper = json("LOUD-IMPORT.JSON", {schema:"loud.import.v1", tracks:[{file:"rich/song.mp3"}]});
    const canonical = json("codec-import.json", {schema:"loud.import.v1", tracks:[{file:"compatible/song.mp3"}]});
    const audio = new File(["audio"], "song.mp3");
    expect((await prepareImportBundle([upper, canonical, audio])).at(-1)?.path).toBe("compatible/song.mp3");
    expect((await prepareImportBundle([upper, audio])).at(-1)?.path).toBe("rich/song.mp3");
    await expect(prepareImportBundle([upper, json("custom.json", {schema:"loud.import.v1", tracks:[]})])).rejects.toThrow("Multiple import manifests");
  });

  test("ignored same-target sidecars cannot conflict with inline artwork filenames", async () => {
    const inline = {...descriptor, file:"inline/cover.png"};
    const manifest = json("loud-import.json", {schema:"loud.import.v1", tracks:[
      {file:"song.mp3", identifiers:{spotify_track_id:"song"}, artwork:inline}
    ], playlists:[{name:" Mix ", artwork:inline}]});
    const trackSide = json("track-artwork.json", {schema:"s2y.track-artwork.v1", tracks:[
      {fingerprint:" spotify:track:song ", artwork:{...descriptor,file:"ignored-track/cover.png"}}
    ]});
    const playlistSide = json("playlist-artwork.json", {schema:"s2y.playlist-artwork.v1", playlists:[
      {name:"Mix", artwork:{...descriptor,file:"ignored-playlist/cover.png"}}
    ]});
    const entries = await prepareImportBundle([manifest,trackSide,playlistSide,new File(["audio"],"song.mp3"),new File(["image"],"cover.png")]);
    expect(entries.at(-1)?.path).toBe("inline/cover.png");
    expect(entries[1].file).toBe(trackSide);
    expect(entries[2].file).toBe(playlistSide);
  });

  test("the first sidecar descriptor wins and null inline artwork permits it", async () => {
    const manifest = json("codec-import.json", {schema:"loud.import.v1",tracks:[{fingerprint:"exact",artwork:null}]});
    const sidecar = json("track-artwork.json", {schema:"s2y.track-artwork.v1",tracks:[
      {fingerprint:"exact",artwork:{...descriptor,file:"first/cover.png"}},
      {fingerprint:"exact",artwork:{...descriptor,file:"ignored/cover.png"}}
    ]});
    expect((await prepareImportBundle([manifest,sidecar,new File(["image"],"cover.png")])).at(-1)?.path).toBe("first/cover.png");
  });

  test("invalid inline artwork retains precedence for server diagnostics", async () => {
    const manifest = json("codec-import.json", {schema:"loud.import.v1",tracks:[{fingerprint:"exact",artwork:false}]});
    const sidecar = json("track-artwork.json", {schema:"s2y.track-artwork.v1",tracks:[
      {fingerprint:"exact",artwork:{...descriptor,file:"ignored/cover.png"}}
    ]});
    const entries = await prepareImportBundle([manifest,sidecar,new File(["image"],"cover.png")]);
    expect(entries.at(-1)?.path).toBe("cover.png");
    expect(entries[0].file).toBe(manifest);
  });

  test("prefers the richer S2Y loud manifest; keeps original inline fields and sidecars", async () => {
    const manifest = json("loud-import.json", { schema: "loud.import.v1", source: { base_path: "media" }, tracks: [
      { file: "audio/song.mp3", fingerprint: "exact", artwork: descriptor }
    ], playlists: [{ name: "Mix", artwork: descriptor }] });
    const sidecar = json("track-artwork.json", { schema: "s2y.track-artwork.v1", base_path: "extra", tracks: [
      { fingerprint: "matched", artwork: { ...descriptor, file: "restored.png" } }
    ] });
    const entries = await prepareImportBundle([
      sidecar, json("codec-import.json", { schema: "loud.import.v1", tracks: [] }), manifest,
      new File(["original audio"], "song.mp3"), new File(["original image"], "cover.png"), new File(["restored image"], "restored.png")
    ]);
    expect(entries.map((entry) => entry.path)).toEqual([
      "track-artwork.json", "codec-import.json", "loud-import.json", "media/audio/song.mp3", "media/artwork/cover.png", "extra/restored.png"
    ]);
    expect(entries.find((entry) => entry.path === "loud-import.json")!.file).toBe(manifest);
    expect(JSON.parse(await manifest.text()).tracks[0].artwork).toEqual(descriptor);
    expect(entries[0].file).toBe(sidecar);
  });

  test("folder selection retains nested roots and disambiguates equal basenames", async () => {
    const manifest = nested(json("codec-import.json", { schema: "loud.import.v1", tracks: [{ file: "a/song.mp3" }, { file: "b/song.mp3" }] }), "bundle/codec-import.json");
    const entries = await prepareImportBundle([
      manifest, nested(new File(["one"], "song.mp3"), "bundle/a/song.mp3"), nested(new File(["two"], "song.mp3"), "bundle/b/song.mp3")
    ]);
    expect(entries.map((entry) => entry.path)).toEqual(["bundle/codec-import.json", "bundle/a/song.mp3", "bundle/b/song.mp3"]);
  });

  test("flat ambiguous audio never silently maps one file to two tracks", async () => {
    const manifest = json("codec-import.json", { schema: "loud.import.v1", tracks: [{ file: "song.mp3" }, { file: "nested/song.mp3" }] });
    await expect(prepareImportBundle([manifest, new File(["one"], "song.mp3")])).rejects.toThrow("Select the bundle folder");
  });

  test("sidecars and unrelated JSON cannot become the main manifest", async () => {
    await expect(prepareImportBundle([json("track-artwork.json", { schema: "s2y.track-artwork.v1", tracks: [] })])).rejects.toThrow("Include loud-import.json");
    const main = json("custom.json", { schema: "loud.import.v1", tracks: [] });
    const selected = await prepareImportBundle([json("checksums.json", {}), main]);
    expect(selected).toHaveLength(2);
    await expect(prepareImportBundle([main, json("other.json", { schema: "loud.import.v1", tracks: [] })])).rejects.toThrow("Multiple import manifests");
  });

  test("invalid descriptors stay available for server diagnostics without repackaging unsafe paths", async () => {
    const manifest = json("codec-import.json", { schema: "loud.import.v1", tracks: [
      { file: "audio/song.mp3", artwork: { ...descriptor, file: "../cover.png" } }
    ] });
    const entries = await prepareImportBundle([manifest, new File(["audio"], "song.mp3"), new File(["image"], "cover.png")]);
    expect(entries.map((entry) => entry.path)).toEqual(["codec-import.json", "audio/song.mp3", "cover.png"]);
    await expect(prepareImportBundle([nested(manifest, "../codec-import.json")])).rejects.toThrow("cannot leave");
  });

  test("duplicate selected file paths and malformed manifests fail before upload", async () => {
    const manifest = json("codec-import.json", { schema: "loud.import.v1", tracks: [] });
    await expect(prepareImportBundle([manifest, manifest])).rejects.toThrow("Duplicate bundle path");
    await expect(prepareImportBundle([json("codec-import.json", null)])).rejects.toThrow("tracks array");
  });
});

describe("ZIP64 storage writer", () => {
  test("keeps original bytes, CRC32 and Unicode paths with valid end records", async () => {
    const manifest = json("loud-import.json", { schema: "loud.import.v1", tracks: [] });
    const content = new File(["123456789"], "café.png");
    const progress: number[] = [];
    const zip = new Uint8Array(await (await buildImportBundle([manifest, content], (fraction) => progress.push(fraction))).arrayBuffer());
    const view = new DataView(zip.buffer);
    let offset = 0;
    for (const file of [manifest, content]) {
      expect(view.getUint32(offset, true)).toBe(0x04034b50);
      expect(view.getUint16(offset + 6, true) & 0x800).toBe(0x800);
      const nameLength = view.getUint16(offset + 26, true), extraLength = view.getUint16(offset + 28, true);
      expect(new TextDecoder().decode(zip.subarray(offset + 30, offset + 30 + nameLength))).toBe(file.name);
      const size = Number(view.getBigUint64(offset + 30 + nameLength + 4, true));
      expect(size).toBe(file.size);
      const dataStart = offset + 30 + nameLength + extraLength;
      expect(zip.slice(dataStart, dataStart + size)).toEqual(new Uint8Array(await file.arrayBuffer()));
      if (file === content) expect(view.getUint32(offset + 14, true)).toBe(0xcbf43926); // Published CRC32 vector.
      offset = dataStart + size;
    }
    expect(view.getUint32(offset, true)).toBe(0x02014b50);
    expect(view.getUint32(zip.length - 98, true)).toBe(0x06064b50);
    expect(view.getBigUint64(zip.length - 98 + 48, true)).toBe(BigInt(offset));
    expect(view.getUint32(zip.length - 22, true)).toBe(0x06054b50);
    expect(progress.at(-1)).toBe(1);
  });

  test("headers retain sizes and offsets above 4 GiB without allocating those files", () => {
    const size = 5 * 1024 ** 3 + 123, offset = 16 * 1024 ** 3 + 789;
    const { local, central } = zip64EntryHeaders("audio.mp3", size, 17, offset);
    const l = new DataView(local.buffer), c = new DataView(central.buffer);
    expect(l.getBigUint64(30 + 9 + 4, true)).toBe(BigInt(size));
    expect(c.getBigUint64(46 + 9 + 20, true)).toBe(BigInt(offset));
    expect(c.getUint32(42, true)).toBe(0xffffffff);
    expect(() => zip64EntryHeaders("../bad", 0, 0, 0)).toThrow("cannot leave");
  });

  test("large audio is read in bounded slices, never through the entire File arrayBuffer", async () => {
    const audio = new File([new Uint8Array(2 * 1024 * 1024 + 1)], "song.mp3");
    const originalSlice = audio.slice.bind(audio);
    const slices: number[] = [];
    audio.arrayBuffer = () => { throw new Error("Whole-file read is forbidden"); };
    audio.slice = (start = 0, end = audio.size, type) => { slices.push(end - start); return originalSlice(start, end, type); };
    const manifest = json("codec-import.json", { schema: "loud.import.v1", tracks: [{ file: "song.mp3" }] });
    const archive = await buildImportBundle([manifest, audio]);
    expect(archive.size).toBeGreaterThan(audio.size);
    expect(slices).toHaveLength(9);
    expect(Math.max(...slices)).toBeLessThanOrEqual(256 * 1024);
  });
});

test("artwork summaries distinguish preserved, missing and failed covers without double-counting aggregate", () => {
  expect(artworkImportSummary({})).toEqual([]);
  expect(artworkImportSummary({ track_artwork_imported: 2, playlist_artwork_imported: 3, artwork_imported: 5,
    artwork_already_present: 7, artwork_missing: 1, artwork_failed: 2 })).toEqual([
    "2 track covers imported", "3 playlist covers imported", "7 existing covers kept", "1 cover missing", "2 cover imports failed"
  ]);
});

test("desktop merge and download summaries expose artwork and additive playlist counters", () => {
  const summary = syncTransferSummary("Merged", {
    tracks_uploaded: 2, tracks_matched: 3, tracks_added: 2, tracks_skipped: 3,
    playlists_added: 1, playlists_updated: 2, playlist_updates: 3,
    track_artwork_uploaded: 1, playlist_artwork_uploaded: 2, artwork_uploaded: 3,
    artwork_already_present: 4, artwork_missing: 1, artwork_failed: 1
  });
  expect(summary).toContain("Merged · 2 tracks transferred · 3 tracks matched · 2 new tracks");
  expect(summary).toContain("1 playlist added · 2 playlists updated");
  expect(summary).toContain("1 track cover imported · 2 playlist covers imported");
  expect(summary).toContain("4 existing covers kept · 1 cover missing · 1 cover import failed");
  expect(summary).not.toContain("already local");
  expect(syncTransferSummary("Downloaded", { tracks_downloaded: 1, artwork_downloaded: 1 })).toBe("Downloaded · 1 track transferred · 1 cover imported");
});

test("bundle summary separates repaired audio from new and matched tracks", () => {
  expect(bundleImportSummary({added:2,existing:5,audio_restored:3,track_artwork_imported:1})).toBe(
    "Import · 2 new · 5 existing · 3 missing audio files restored · 1 track cover imported"
  );
  expect(bundleImportSummary({added:0,existing:1,audio_restored:1})).toContain("1 missing audio file restored");
  expect(bundleImportSummary({added:0,existing:5})).toBe("Import · 0 new · 5 existing");
});
