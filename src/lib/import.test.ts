import { describe, expect, test } from "bun:test";
import {
  fingerprintFor,
  fnv1a64,
  identityForImportTrack,
  identityForPlaylistRef,
  parseId3
} from "./import";

describe("import identity", () => {
  test("fnv1a64 matches the published test vectors (and so the Rust stable_id)", () => {
    expect(fnv1a64("")).toBe("cbf29ce484222325");
    expect(fnv1a64("a")).toBe("af63dc4c8601ec8c");
    expect(fnv1a64("foobar")).toBe("85944171f73967e8");
  });

  test("fingerprints normalize whitespace and case like the desktop", () => {
    expect(fingerprintFor("  The  Song ", "ARTIST", "Album")).toBe(
      fingerprintFor("the song", "artist", "album")
    );
    expect(fingerprintFor("A", "B", "C")).toBe(fnv1a64("a|b|c"));
  });
});

describe("loud.import.v1 identity", () => {
  test("follows the documented precedence", () => {
    expect(identityForImportTrack({ fingerprint: "custom" })).toBe("custom");
    expect(
      identityForImportTrack({
        identifiers: { isrc: "usrc12100543", spotify_track_id: "sp" }
      })
    ).toBe("isrc:USRC12100543");
    expect(identityForImportTrack({ identifiers: { musicbrainz_recording_id: "mb" } })).toBe("mbid:mb");
    expect(identityForImportTrack({ identifiers: { spotify_track_id: "sp" } })).toBe("spotify:track:sp");
    expect(identityForImportTrack({ identifiers: { youtube_video_id: "yt" } })).toBe("youtube:yt");
    expect(identityForImportTrack({ title: "A", artist: "B", album: "C" })).toBe(
      fingerprintFor("A", "B", "C")
    );
  });

  test("resolves playlist refs by file, identifiers, or fingerprint", () => {
    const byFile = new Map([["Doja Cat/Planet Her/Woman.mp3", "isrc:X"]]);
    expect(identityForPlaylistRef("Doja Cat/Planet Her/Woman.mp3", byFile)).toBe("isrc:X");
    expect(identityForPlaylistRef({ identifiers: { isrc: "y" } }, byFile)).toBe("isrc:Y");
    expect(identityForPlaylistRef({ fingerprint: "direct" }, byFile)).toBe("direct");
    expect(identityForPlaylistRef("missing.mp3", byFile)).toBeNull();
  });
});

describe("id3 parsing", () => {
  function textFrame(id: string, value: string): Uint8Array {
    const text = new TextEncoder().encode(value);
    const frame = new Uint8Array(10 + 1 + text.length);
    frame.set(new TextEncoder().encode(id), 0);
    const size = 1 + text.length;
    frame[4] = (size >>> 24) & 0xff;
    frame[5] = (size >>> 16) & 0xff;
    frame[6] = (size >>> 8) & 0xff;
    frame[7] = size & 0xff;
    frame[10] = 3; // utf-8
    frame.set(text, 11);
    return frame;
  }

  test("reads the common v2.3 text frames", () => {
    const frames = [
      textFrame("TIT2", "Night Drive"),
      textFrame("TPE1", "Neon Artist"),
      textFrame("TALB", "City Tapes"),
      textFrame("TRCK", "7/12"),
      textFrame("TYER", "1999")
    ];
    const framesSize = frames.reduce((sum, frame) => sum + frame.length, 0);
    const buffer = new Uint8Array(10 + framesSize + 32);
    buffer.set(new TextEncoder().encode("ID3"), 0);
    buffer[3] = 3; // v2.3
    buffer[6] = (framesSize >>> 21) & 0x7f;
    buffer[7] = (framesSize >>> 14) & 0x7f;
    buffer[8] = (framesSize >>> 7) & 0x7f;
    buffer[9] = framesSize & 0x7f;
    let offset = 10;
    for (const frame of frames) {
      buffer.set(frame, offset);
      offset += frame.length;
    }

    const tags = parseId3(buffer.buffer);
    expect(tags.title).toBe("Night Drive");
    expect(tags.artist).toBe("Neon Artist");
    expect(tags.album).toBe("City Tapes");
    expect(tags.trackNumber).toBe(7);
    expect(tags.year).toBe(1999);
  });

  test("falls back to ID3v1 tails", () => {
    const buffer = new Uint8Array(200);
    const tail = buffer.subarray(buffer.length - 128);
    tail.set(new TextEncoder().encode("TAG"), 0);
    tail.set(new TextEncoder().encode("Old Title"), 3);
    tail.set(new TextEncoder().encode("Old Artist"), 33);

    const tags = parseId3(buffer.buffer);
    expect(tags.title).toBe("Old Title");
    expect(tags.artist).toBe("Old Artist");
  });
});
