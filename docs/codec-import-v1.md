# Codec import format

`loud.import.v1` is Codec's portable music manifest. The S2Y artwork extension
keeps that version: older manifests still work. A bundle holds the manifest,
audio, and optional original cover images together. It can be a folder or a
ZIP archive, conventionally named `library.loud.zip`.

The artwork sidecars and additive server imports described here require Codec
server **v0.1.5 or later**. See the [server release guide](server-release.md)
for setup.

## What connects to what

```text
S2Y or another exporter
  → manifest + audio + artwork
  → Codec importer
  → your existing Codec server (library database + managed media)
  → web / installed web app / Swift iPhone app
```

The server is the shared source of music. The web interface is one client;
the Swift app is another. The Rust CLI can prepare a local import library. Importing
adds data to the existing server; it does not create a replacement server.
The phone reads the normal library, audio, and artwork endpoints, so receiving
these imported songs and covers does not require a new phone version.

## Folder structure

```text
my-collection/
├── loud-import.json          preferred main manifest, including covers
├── codec-import.json         optional alternative main manifest
├── playlist-artwork.json     optional s2y.playlist-artwork.v1 sidecar
├── track-artwork.json        optional s2y.track-artwork.v1 sidecar
├── audio/                    actual MP3, M4A, FLAC, or WAV files
├── artwork/                  original JPEG or PNG images
├── provenance.json           source records; keep with the bundle
├── checksums.json            source integrity records
└── verification.json         source verification records
```

Only one main manifest is imported. Canonical filenames are case-sensitive.
Browser/server bundle selection prefers
`loud-import.json`, then `codec-import.json`, then an unambiguous JSON document
with `schema: "loud.import.v1"`. Multiple candidates at the selected priority
are rejected. Sidecars are looked up beside that main manifest. The CLI takes
the specific manifest path you give it.

For portable bundles, use relative paths. With `source.base_path: "."`,
`audio/song.mp3` means the audio file beside the manifest under `audio/`.
With `source.base_path: "files"`, it means `files/audio/song.mp3`.
Each sidecar has its **own** `base_path`; it does not inherit the main one.
Legacy local audio imports can use absolute paths, but ZIP and artwork paths
must remain inside the bundle. Do not flatten folders with repeated filenames.

## Main manifest

This minimal example matches both artwork sidecars below. The song details,
`example:song-1` fingerprint, and audio filename are placeholders. Supply your
own `audio/song.mp3`; no audio is included with the example downloads.
Preserve an existing track's actual fingerprint when migrating it.

[Download loud-import.json](../site/examples/loud-import.json).

```json
{
  "schema": "loud.import.v1",
  "source": { "base_path": "." },
  "tracks": [
    {
      "file": "audio/song.mp3",
      "fingerprint": "example:song-1",
      "title": "Example Song",
      "artist": "Example Artist",
      "liked": true
    }
  ],
  "playlists": [
    {
      "name": "My Mix",
      "mode": "append",
      "tracks": [{ "fingerprint": "example:song-1" }]
    }
  ]
}
```

Tracks can also include `album`, `album_artist`, `genre`, `year`, `track_number`,
`disc_number`, `explicit`, `duration_ms`, `duration_seconds`, `identifiers`,
`source_urls`, per-track `playlists`, and an inline `artwork` descriptor. Use milliseconds when both
duration fields exist. Optional scalar metadata may be omitted or `null`;
identity maps use string values. Disc number, explicit flag, identifiers, and
source URLs survive supported import, transfer, and export paths. Unknown
source audit documents are not automatically stored in the server database.

See [the complete JSON Schema](codec-import.schema.json) for exact fields.

## Artwork sidecars

Place the two sidecars beside `loud-import.json`. Each uses its own
`base_path: "."`, so both examples look for `artwork/cover.jpg` in that same
folder. Download the [actual example cover](../site/examples/artwork/cover.jpg)
and save it at that path. The image is Jean-François Millet's *Autumn Landscape
with a Flock of Turkeys*, supplied by The Met as public-domain/CC0 artwork;
[source, license, and setup notes](../site/examples/CREDITS.txt) are included.
The JPEG is unchanged: 98,487 bytes, 600 × 489 pixels. Both descriptors below
contain its real SHA-256, MIME type, and dimensions.

### track-artwork.json

This targets **the song's exact fingerprint**, `example:song-1` in the main
manifest. It is not the song title or playlist name. Existing tracks can also
receive missing covers this way. [Download track-artwork.json](../site/examples/track-artwork.json).

```json
{
  "schema": "s2y.track-artwork.v1",
  "base_path": ".",
  "tracks": [
    {
      "fingerprint": "example:song-1",
      "artwork": {
        "file": "artwork/cover.jpg",
        "sha256": "94f349d7962f0472d0f8318af881c6426f12321966e97892894951f4519cc0d8",
        "mime_type": "image/jpeg",
        "width": 600,
        "height": 489
      }
    }
  ]
}
```

### playlist-artwork.json

This targets **the playlist's name**, `My Mix` in the main manifest. It does
not use a track fingerprint or a playlist ID.
[Download playlist-artwork.json](../site/examples/playlist-artwork.json).

```json
{
  "schema": "s2y.playlist-artwork.v1",
  "base_path": ".",
  "playlists": [
    {
      "name": "My Mix",
      "artwork": {
        "file": "artwork/cover.jpg",
        "sha256": "94f349d7962f0472d0f8318af881c6426f12321966e97892894951f4519cc0d8",
        "mime_type": "image/jpeg",
        "width": 600,
        "height": 489
      }
    }
  ]
}
```

Both examples reuse one image; separate track and playlist images are also
supported. When replacing the image, update its file path, SHA-256, MIME type,
width, and height together. When adapting the song or playlist, change the
fingerprint or name consistently with the main manifest. An optional row-level
`origin` is informational. Playlist names resolve to destination IDs; source
IDs are not assumed to match server IDs.

Inline artwork takes precedence over a sidecar for the same target. Existing
destination covers are preserved. Valid external artwork takes precedence
over embedded fallback art on newly imported audio. Missing artwork never
clears an existing cover. Invalid descriptors report errors separately from
valid audio and membership changes.

Artwork descriptors require `file`, `sha256`, `mime_type`, `width`, and
`height`. JPEG/PNG originals are retained byte-for-byte; thumbnails are
separate. Validation checks the hash, decoded type and dimensions, a 12 MiB
file limit, an 8192-pixel edge limit, and a 16,777,216-pixel total limit.
Traversal and symlink escapes are rejected. Optional `source_url`,
`spotify_url`, `license_url`, `attribution_url`, and `provenance` never cause
remote image downloads. Keep the original bundle for its full provenance;
server exports regenerate image descriptors, not all original source records.

Standalone schemas: [track sidecar](s2y-track-artwork.schema.json) and
[playlist sidecar](s2y-playlist-artwork.schema.json).

## Identity, likes, and playlist rules

An explicit `fingerprint` is exact: distinct fingerprints stay distinct even
when title and artist match. Without one, the importer derives identity from
ISRC, MusicBrainz recording ID, Spotify track ID, YouTube video ID, then
normalized title + artist + album, in that order. Spotify album IDs are metadata,
not song identities. For migrations, retain the original Codec fingerprints.

Playlist entries can reference a fingerprint, identifiers, or a relative audio
filename. They point at canonical tracks, not additional audio copies.
Server imports are additive: existing track metadata and likes remain; incoming
likes can add likes; existing playlist order remains and missing members append
in incoming order. Empty playlists are supported. Exact trimmed playlist names
match; ambiguous names fail rather than silently merging unrelated playlists.
Rename the incoming playlist explicitly when you want a separate playlist.

Each track occurs at most once in a playlist. Repeated source occurrences
collapse to the first position. A playlist such as `Codec Liked Songs (snapshot)`
is an ordinary playlist, not a replacement for current Liked Songs.

Local manifest imports also understand `mode: "replace"`; use it only for a
local playlist your exporter owns. Server merges always append and preserve
existing membership. Use `append` for ordinary imports.

## How to import

| Entry point | What to supply | Destination |
| --- | --- | --- |
| Web / mobile web | Settings → Import music: ZIP, bundle folder, or manifest and all referenced files | Connected server |
| Rust CLI | Explicit manifest path, plus optional server URL and private token file | Local library, optionally server |
| Swift app | Refresh the connected library after import | Receives normal server data; no bundle picker |

Browser folder selection preserves paths. Flat file selection is accepted only
when filename references are unambiguous. Loose selections are packaged into
ZIP64 and sent to the same server importer as an uploaded ZIP. Once uploaded,
job progress survives a browser refresh while the server stays running. ZIP64
supports archives over 4 GiB; this does not bypass upload limits imposed by your
browser, reverse proxy, or server. Large collections are better imported with
the CLI, which sends missing audio files individually.

Build and run the CLI from the repository root:

```bash
cargo build --release --manifest-path src-tauri/Cargo.toml --bin codec_import
mkdir -p /path/to/staging-library
src-tauri/target/release/codec_import \
  /path/to/staging-library /path/to/bundle/loud-import.json \
  --server https://your-codec-server.example \
  --token-file /private/path/codec-token \
  --report /path/to/private/import-report.json
```

Omit `--server` and `--token-file` for local import only. Unzip archives before
using the CLI. Use a dedicated staging root: server merge scans that entire
local library. Never put a real token in the command line. Repeating the same
import reuses exact identities, completed media uploads, and memberships.

Rust CLI server uploads use additive merge, not wholesale snapshot
replacement. Download sync is different: it mirrors server playlist
and liked state into the local library while retaining original covers.

## Export and verification

Share library exports a ZIP containing `codec-import.json`, available audio,
and managed JPEG/PNG track/playlist covers. Tracks without stored audio are
omitted from that export; legacy GIF/WebP covers remain readable through the
API but are not exported as new artwork descriptors. Audio and original image bytes are preserved. Metadata,
ordered unique memberships, and likes are included. The exported manifest need
not reproduce the source JSON byte-for-byte; keep your original bundle for its
source provenance, checksum manifest, and previous verification records.

Review new/matched/skipped tracks, playlist/like changes, and **separate**
artwork imported/already-present/missing/failed counters. A completed job may
still have skipped files or artwork warnings. Check those rather than relying
only on its final state. Missing optional art does not mean lost music.

For the S2Y migration workflow, detailed limits, collision rules, reports,
and round-trip tests, see [S2Y artwork import](s2y-artwork-import.md).
