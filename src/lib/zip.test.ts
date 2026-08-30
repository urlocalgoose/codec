import { describe, expect, test } from "bun:test";
import { readZipEntries, zipEntryBlob } from "./zip";

interface TestEntry {
  name: string;
  data: Uint8Array;
  method?: number;
  storedData?: Uint8Array;
}

function u16(view: DataView, offset: number, value: number) {
  view.setUint16(offset, value, true);
}
function u32(view: DataView, offset: number, value: number) {
  view.setUint32(offset, value, true);
}

/** Store-method zip builder, just enough for the reader tests. */
function buildZip(entries: TestEntry[]): Uint8Array {
  const encoder = new TextEncoder();
  const chunks: Uint8Array[] = [];
  const centrals: { entry: TestEntry; offset: number; stored: Uint8Array }[] = [];
  let offset = 0;

  for (const entry of entries) {
    const name = encoder.encode(entry.name);
    const stored = entry.storedData ?? entry.data;
    const header = new Uint8Array(30);
    const view = new DataView(header.buffer);
    u32(view, 0, 0x04034b50);
    u16(view, 4, 20);
    u16(view, 8, entry.method ?? 0);
    u32(view, 18, stored.length);
    u32(view, 22, entry.data.length);
    u16(view, 26, name.length);
    centrals.push({ entry, offset, stored });
    chunks.push(header, name, stored);
    offset += header.length + name.length + stored.length;
  }

  const directoryOffset = offset;
  for (const { entry, offset: headerOffset, stored } of centrals) {
    const name = encoder.encode(entry.name);
    const central = new Uint8Array(46);
    const view = new DataView(central.buffer);
    u32(view, 0, 0x02014b50);
    u16(view, 10, entry.method ?? 0);
    u32(view, 20, stored.length);
    u32(view, 24, entry.data.length);
    u16(view, 28, name.length);
    u32(view, 42, headerOffset);
    chunks.push(central, name);
    offset += central.length + name.length;
  }

  const eocd = new Uint8Array(22);
  const view = new DataView(eocd.buffer);
  u32(view, 0, 0x06054b50);
  u16(view, 8, entries.length);
  u16(view, 10, entries.length);
  u32(view, 12, offset - directoryOffset);
  u32(view, 16, directoryOffset);
  chunks.push(eocd);

  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(total);
  let cursor = 0;
  for (const chunk of chunks) {
    out.set(chunk, cursor);
    cursor += chunk.length;
  }
  return out;
}

describe("zip reader", () => {
  test("lists entries and slices stored data back out", async () => {
    const audio = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
    const manifest = new TextEncoder().encode(`{"schema":"loud.import.v1"}`);
    const zip = new Blob([
      buildZip([
        { name: "codec-import.json", data: manifest },
        { name: "files/Artist/Album/Song.mp3", data: audio }
      ])
    ]);

    const entries = await readZipEntries(zip);
    expect(entries.map((entry) => entry.name)).toEqual([
      "codec-import.json",
      "files/Artist/Album/Song.mp3"
    ]);

    const song = entries[1];
    expect(song.uncompressedSize).toBe(audio.length);
    const blob = await zipEntryBlob(zip, song, "audio/mpeg");
    expect(new Uint8Array(await blob.arrayBuffer())).toEqual(audio);
    expect(blob.type).toBe("audio/mpeg");

    const text = await (await zipEntryBlob(zip, entries[0])).text();
    expect(JSON.parse(text).schema).toBe("loud.import.v1");
  });

  test("inflates deflate entries (the manifest in real exports)", async () => {
    if (typeof CompressionStream === "undefined") {
      return;
    }
    const manifest = new TextEncoder().encode(`{"schema":"loud.import.v1","tracks":[]}`);
    const compressed = new Uint8Array(
      await new Response(
        new Blob([manifest]).stream().pipeThrough(new CompressionStream("deflate-raw"))
      ).arrayBuffer()
    );
    const zip = new Blob([
      buildZip([{ name: "codec-import.json", data: manifest, method: 8, storedData: compressed }])
    ]);

    const entries = await readZipEntries(zip);
    const text = await (await zipEntryBlob(zip, entries[0])).text();
    expect(JSON.parse(text).schema).toBe("loud.import.v1");
  });

  test("rejects non-zip blobs", async () => {
    await expect(readZipEntries(new Blob([new Uint8Array(100)]))).rejects.toThrow("Not a zip");
  });
});
