/** Minimal zip reader over a Blob, for importing Codec library exports
 * without unzipping. Reads the central directory from the tail, then hands
 * out entries as Blob slices — a multi-gigabyte zip never enters memory.
 * Supports Store and Deflate entries plus zip64 (exports pass 4GB easily). */

export interface ZipEntry {
  name: string;
  method: number; // 0 = store, 8 = deflate
  compressedSize: number;
  uncompressedSize: number;
  headerOffset: number;
}

const EOCD_SIGNATURE = 0x06054b50;
const EOCD64_LOCATOR_SIGNATURE = 0x07064b50;
const EOCD64_SIGNATURE = 0x06064b50;
const CENTRAL_SIGNATURE = 0x02014b50;
const LOCAL_SIGNATURE = 0x04034b50;

export async function readZipEntries(archive: Blob): Promise<ZipEntry[]> {
  // The end-of-central-directory record sits in the last 22 bytes plus an
  // optional comment (max 64KB).
  const tailSize = Math.min(archive.size, 22 + 65535 + 20);
  const tailStart = archive.size - tailSize;
  const tail = new DataView(await archive.slice(tailStart).arrayBuffer());

  let eocdOffset = -1;
  for (let cursor = tail.byteLength - 22; cursor >= 0; cursor -= 1) {
    if (tail.getUint32(cursor, true) === EOCD_SIGNATURE) {
      eocdOffset = cursor;
      break;
    }
  }
  if (eocdOffset < 0) {
    throw new Error("Not a zip file (no end-of-central-directory record).");
  }

  let entryCount = tail.getUint16(eocdOffset + 10, true);
  let directorySize = tail.getUint32(eocdOffset + 12, true);
  let directoryOffset = tail.getUint32(eocdOffset + 16, true);

  // zip64: the 32-bit fields saturate and the real record sits earlier.
  if (entryCount === 0xffff || directorySize === 0xffffffff || directoryOffset === 0xffffffff) {
    let locatorOffset = -1;
    for (let cursor = eocdOffset - 20; cursor >= 0; cursor -= 1) {
      if (tail.getUint32(cursor, true) === EOCD64_LOCATOR_SIGNATURE) {
        locatorOffset = cursor;
        break;
      }
    }
    if (locatorOffset < 0) {
      throw new Error("zip64 archive is missing its locator record.");
    }
    const eocd64Position = Number(tail.getBigUint64(locatorOffset + 8, true));
    const eocd64 = new DataView(await archive.slice(eocd64Position, eocd64Position + 56).arrayBuffer());
    if (eocd64.getUint32(0, true) !== EOCD64_SIGNATURE) {
      throw new Error("zip64 archive has a corrupt end record.");
    }
    entryCount = Number(eocd64.getBigUint64(32, true));
    directorySize = Number(eocd64.getBigUint64(40, true));
    directoryOffset = Number(eocd64.getBigUint64(48, true));
  }

  const directory = new DataView(
    await archive.slice(directoryOffset, directoryOffset + directorySize).arrayBuffer()
  );
  const decoder = new TextDecoder();
  const entries: ZipEntry[] = [];
  let cursor = 0;

  for (let index = 0; index < entryCount && cursor + 46 <= directory.byteLength; index += 1) {
    if (directory.getUint32(cursor, true) !== CENTRAL_SIGNATURE) {
      break;
    }
    const method = directory.getUint16(cursor + 10, true);
    let compressedSize: number = directory.getUint32(cursor + 20, true);
    let uncompressedSize: number = directory.getUint32(cursor + 24, true);
    const nameLength = directory.getUint16(cursor + 28, true);
    const extraLength = directory.getUint16(cursor + 30, true);
    const commentLength = directory.getUint16(cursor + 32, true);
    let headerOffset: number = directory.getUint32(cursor + 42, true);
    const name = decoder.decode(
      new Uint8Array(directory.buffer, directory.byteOffset + cursor + 46, nameLength)
    );

    // zip64 extra field carries the real values for saturated fields, in
    // the order uncompressed, compressed, offset — only saturated ones.
    let extraCursor = cursor + 46 + nameLength;
    const extraEnd = extraCursor + extraLength;
    while (extraCursor + 4 <= extraEnd) {
      const id = directory.getUint16(extraCursor, true);
      const size = directory.getUint16(extraCursor + 2, true);
      if (id === 0x0001) {
        let fieldCursor = extraCursor + 4;
        if (uncompressedSize === 0xffffffff) {
          uncompressedSize = Number(directory.getBigUint64(fieldCursor, true));
          fieldCursor += 8;
        }
        if (compressedSize === 0xffffffff) {
          compressedSize = Number(directory.getBigUint64(fieldCursor, true));
          fieldCursor += 8;
        }
        if (headerOffset === 0xffffffff) {
          headerOffset = Number(directory.getBigUint64(fieldCursor, true));
        }
      }
      extraCursor += 4 + size;
    }

    entries.push({ name, method, compressedSize, uncompressedSize, headerOffset });
    cursor += 46 + nameLength + extraLength + commentLength;
  }

  return entries;
}

/** The entry's raw bytes as a lazy Blob slice (Store) or an inflated Blob
 * (Deflate — used only for the small manifest in Codec exports). */
export async function zipEntryBlob(archive: Blob, entry: ZipEntry, type = ""): Promise<Blob> {
  const local = new DataView(
    await archive.slice(entry.headerOffset, entry.headerOffset + 30).arrayBuffer()
  );
  if (local.getUint32(0, true) !== LOCAL_SIGNATURE) {
    throw new Error(`Corrupt zip entry: ${entry.name}`);
  }
  const nameLength = local.getUint16(26, true);
  const extraLength = local.getUint16(28, true);
  const dataStart = entry.headerOffset + 30 + nameLength + extraLength;
  const compressed = archive.slice(dataStart, dataStart + entry.compressedSize, type);

  if (entry.method === 0) {
    return compressed;
  }
  if (entry.method === 8) {
    const stream = compressed.stream().pipeThrough(new DecompressionStream("deflate-raw"));
    return await new Response(stream).blob();
  }
  throw new Error(`Unsupported zip compression method ${entry.method} for ${entry.name}`);
}
