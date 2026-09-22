# S2Y artwork import and additive server merge

Codec can import an S2Y music bundle into a local library, retain its original
track and playlist images, and merge the result into an existing Codec server.
The server merge uses existing authenticated `/api/v1` endpoints. Receiving
new tracks, playlists, and JPEG covers does not require an iPhone app update.

This document describes the implementation and its verification paths. It is
not a record that any particular bundle has been imported into a live server.

## Bundle and artwork inputs

A bundle can contain:

```text
loud-import.json            preferred loud.import.v1 audio/playlist manifest
codec-import.json           optional compatible alternative manifest
track-artwork.json          s2y.track-artwork.v1 sidecar
playlist-artwork.json       s2y.playlist-artwork.v1 sidecar
audio/...                   original audio files
artwork/...                 original JPEG/PNG images
```

The normal manifest supports an optional `artwork` descriptor on individual
tracks and playlists. The same descriptor can appear in the sibling sidecars:

```json
{
  "file": "artwork/cover.jpg",
  "sha256": "<64 hexadecimal characters matching the image bytes>",
  "mime_type": "image/jpeg",
  "width": 640,
  "height": 640,
  "source_url": "https://example.com/original-cover.jpg",
  "provenance": { "provider": "s2y" }
}
```

The digest above is a placeholder, not a valid import value. `file`, `sha256`,
`mime_type`, `width`, and `height` are required. `source_url`, `spotify_url`,
`license_url`, `attribution_url`, and `provenance` are optional source metadata;
Codec does not fetch those URLs. Local import retains descriptor provenance,
but server transfer/export does not retain every ancillary provenance field.
Keep the original bundle and audit documents as the complete source record.

A track sidecar has `schema: "s2y.track-artwork.v1"`, optional `base_path`, and a
`tracks` array of `{ "fingerprint": "...", "artwork": { ... } }` objects. A
playlist sidecar has `schema: "s2y.playlist-artwork.v1"`, optional `base_path`,
and a `playlists` array of `{ "name": "...", "artwork": { ... } }` objects.

Each sidecar resolves files against its own `base_path`, relative to the
manifest directory. Inline descriptors use `source.base_path`. An inline
image wins over a sidecar for the same target. Later duplicate descriptors
for that target do not replace the selected one.

Track artwork targets exact canonical fingerprints, including tracks already
present in the library. An explicit fingerprint never falls back to a similar
title, artist, or album. Normal audio imports retain the existing identifier
rules and unambiguous provider aliases for playlist references; those aliases
are not used to guess a track sidecar target. See
[the import format](codec-import-v1.md) and [JSON Schema](codec-import.schema.json).

An artwork-only import can use a manifest with empty `tracks` and `playlists`
arrays beside the two sidecars. Its targets must already exist locally.

## Validation, storage, and cover preservation

External artwork must satisfy all of these conditions:

- JPEG or PNG, nonempty, no larger than 12,582,912 bytes (12 MiB).
- Positive dimensions, at most 8192 pixels on either edge and 16,777,216
  pixels in total.
- Declared MIME and dimensions match the decoded image, and the SHA-256
  digest matches its exact bytes.
- Relative artwork paths and base folders stay inside the manifest folder;
  absolute paths, parent traversal, and symlink escapes are rejected.

Codec checks dimensions before decoding pixels and bounds decoder allocation.
Invalid or missing images produce artwork diagnostics while independently
valid audio and playlist references still import. An invalid replacement is
reported even when an existing cover would otherwise be retained.

Validated originals are copied into `.loud/artwork/originals/` under a
content-derived filename, using a temporary file and atomic rename. State in
`.loud/state.json` links track fingerprints and playlist IDs to those originals.
The original JPEG or PNG bytes are not recompressed. Display thumbnails are
separate cached JPEGs; generating them never rewrites the originals. Renaming
a playlist or removing the source bundle does not remove its persisted cover.

A cover present in the destination before import wins by default, including
embedded track artwork. Valid external artwork wins over the embedded fallback
on newly imported audio.
Uploading also preserves an existing destination cover. The importer checks
HEAD first; only `404` means missing. Authentication errors, timeouts, and
server errors are reported rather than treated as permission to overwrite.
Uploads use the validated original MIME and bytes. Playlist artwork is sent
only after its destination playlist exists.

## Build and import

Build the headless CLI from the repository root:

```bash
cargo build --manifest-path src-tauri/Cargo.toml --bin codec_import
```

Create an empty staging music directory. Keeping the bundle separate makes
it easier to compare a scan with its manifest and avoids changing source files.
The token file should contain the existing server token and have private
permissions; do not put the token value in a command line or server URL.

Local import, without a server mutation:

```bash
mkdir -p /path/to/staging-library
src-tauri/target/debug/codec_import \
  /path/to/staging-library /path/to/bundle/loud-import.json \
  --report /path/to/reports/local-import.json
```

Additive server import:

```bash
src-tauri/target/debug/codec_import \
  /path/to/staging-library /path/to/bundle/loud-import.json \
  --server https://your-codec-server.example \
  --token-file /private/path/codec-token \
  --report /path/to/reports/server-import.json
```

`--merge` is an optional spelling of the default server behavior. There is no
replacement mode in this CLI. Repeating the command matches already-imported
tracks and skips completed uploads and playlist memberships. The merge scans
the entire local music root; use a staging root containing only the intended
bundle when that is the desired import scope.

`CODEC_AUTH_TOKEN` is also supported, with `LOUD_AUTH_TOKEN` as a legacy
fallback. Explicit `--token` arguments and credentials or query parameters
inside the server URL are rejected. HTTP redirects are not followed by the
transfer client, and arbitrary server response bodies are omitted from errors
so a proxy cannot echo credentials into reports. Report files are written
atomically with private file permissions on Unix.

## Additive merge and collisions

Before contacting the server, the CLI checks that every successful
fingerprint in the local import report is present exactly in the upload scan.
A lost or changed identity aborts even if the total track count still matches.
It then reads a server snapshot to resolve exact fingerprints and playlist
names, and uses individual track metadata, audio, liked,
create-playlist, append-track, and artwork endpoints. It does not submit a
whole-library `/sync/push` or a replacement playlist row.

Existing server track metadata is retained. Only absent fingerprints receive
new metadata; new metadata is written before its audio upload. Incoming likes
may add likes but never clear existing likes. Existing server media is reused.
A failed audio transfer does not append that new track to a playlist.

Regular playlists match by exact trimmed name. A unique destination match
retains its actual server ID, name, and ordered track list. Missing members
are appended in incoming order. New playlists use the ID returned by the
server rather than a locally generated source ID. Empty or ambiguous source
names, duplicate matching destination names, and duplicate remote track
fingerprints stop the merge before server writes. The report records each
source-to-destination playlist mapping.

The local importer also checks playlist names across manifest rows, per-track
memberships, sidecars, and existing folder/state playlists before changing the
library. Distinct trimmed names that normalize to one name, multiple
existing matches, and a name that would reuse a renamed playlist's old ID are
rejected instead of silently combining playlists. Use the exact existing name
or rename the incoming playlist explicitly.

Playlist membership currently stores each canonical track once. If a source
playlist repeats the same fingerprint, later occurrences collapse and the
first occurrence determines its position. Repeated occurrences are not
preserved as separate playlist entries. Distinct explicit fingerprints remain
distinct tracks even when their titles and tags are identical.

Desktop **Merge library into server** uses this same additive transfer path.
The browser packages loose selections into ZIP64 and uses the server bundle
importer, which applies the same preservation rules. No import path uses a
whole-library snapshot push to replace the destination.

## Download, restart, and rescan

A fresh process can rescan the local library without contacting the server:

```bash
src-tauri/target/debug/codec_import /path/to/staging-library \
  --scan --report /path/to/reports/rescan.json
```

A scan report contains library metadata and ordered memberships. Local artwork
references are internal state; HTTP artwork URLs are attached by the running
desktop media server, not by the headless scan command. Validate stored originals
through `.loud/state.json` and their content hashes when checking persistence.

Download into an existing directory:

```bash
mkdir -p /path/to/receiving-library
src-tauri/target/debug/codec_import /path/to/receiving-library \
  --download --server https://your-codec-server.example \
  --token-file /private/path/codec-token \
  --report /path/to/reports/download.json
```

Downloading skips audio for exact fingerprints already on disk. Fresh audio is
imported together with its server track cover: a server original takes
precedence over an embedded fallback in the newly downloaded audio. A cover
already present in the destination before the download, including embedded
artwork, remains intact.

After applying server playlist and liked state locally, the downloader restores
missing covers for matched tracks and playlists. Thus a matched track can
acquire artwork without downloading its audio again. Destination playlists
exist before playlist artwork sidecars are applied. Downloaded JPEG/PNG originals
retain their exact bytes and MIME. Legacy GIF/WebP cover restoration through
external sidecars reports unsupported format rather than replacing local art.

Temporary sync downloads under `.loud/cache/` are not part of the music library.
Only imported managed audio becomes a canonical track; leaving temporary files
on disk cannot add duplicate tracks or make a future download appear complete.

Download is a synchronization operation and can change local playlist and liked
state. The additive server-preservation rules apply to imports into the server.

## Reports and verification

`--report` writes a `codec.import-report.v1` object with `success`, `mode`,
`import` and/or `sync` results, or an `error`. The CLI exits unsuccessfully if
an import or transfer has failures, while still writing the requested report.

| Scope | Fields and meaning |
| --- | --- |
| Local tracks | `new_tracks`, `existing_tracks`, `skipped_tracks`; `track_fingerprints` includes successful new and already-matched canonical targets. |
| Local membership | `playlist_updates` counts references added; `liked_updates` counts local like changes. |
| Local artwork | `track_artwork_imported`, `playlist_artwork_imported`, `artwork_already_present`, `artwork_missing`, `artwork_failed`; `artwork_failures` contains diagnostics for both missing and failed images. |
| Server tracks | `tracks_added` counts new metadata; `tracks_matched` counts existing fingerprints; `tracks_uploaded`, `tracks_downloaded`, and `tracks_skipped` describe audio transfer. |
| Server playlists | `playlists_added`, `playlists_updated`, `playlist_tracks_added`; `playlist_updates` is the membership-add counter retained for compatibility. `playlist_mappings` records source and destination names/IDs and whether creation occurred. |
| Server likes | `liked_updates` counts added likes; zero is expected when incoming likes are already represented. |
| Transferred artwork | `artwork_uploaded`, `artwork_downloaded`, `artwork_already_present`, `artwork_missing`, `artwork_failed`, plus corresponding `track_artwork_*` and `playlist_artwork_*` counters. |
| Transfer failures | `failures` identifies the affected track or playlist and operation. An absent optional source cover is counted as missing, not a transfer error. |

Before using an import result, compare exact fingerprint sets, existing track
metadata and likes, existing playlist IDs/order, new playlist membership order,
and media content hashes. Check that a second import transfers no completed
media and appends no existing membership. Counts alone cannot prove identity
preservation: one missing explicit identity and one unintended fallback
identity can leave the total track count unchanged.

The isolated Rust tests exercise original JPEG/PNG upload and download bytes,
matched-track artwork restoration, destination playlist IDs, ordered additive
membership, repeat imports, ambiguous-name rejection, authentication failures,
conditional-upload conflicts, and unsupported-format preservation. Run them
with the rest of the Rust suite:

```bash
cargo test --manifest-path src-tauri/Cargo.toml
```

## Existing phone and server compatibility

The phone already reads the normal library `artwork_url` fields and streams
from the existing audio/artwork routes. Importing data through those routes
requires neither a new phone binary nor a new schema. Rebuilding this CLI does
not install anything on the phone or restart the running server.

Legacy server executables store JPEG artwork
through the existing API but labels artwork responses `image/jpeg`. JPEG-only
S2Y bundles fit that existing contract. Correct response MIME for PNG and the
additional upload protection below require the updated Go server source to be
built and deployed. Check the deployment record for the running build.

The updated Go artwork handler validates JPEG/PNG bytes within the same limits,
retains originals, and serves actual MIME with cache validators. Existing
embedded GIF/WebP covers remain readable with their real MIME; new external
uploads remain JPEG/PNG-only. Conditional `If-None-Match: *` uploads atomically
refuse an existing cover with `412`, which the CLI counts as already present.
Older servers ignore this condition, so HEAD protects covers observed before
upload but cannot prevent a concurrent cover edit between HEAD and PUT.

## Browser bundles, export, and client compatibility

The web import picker supports ZIPs and loose manifests with their referenced
files; folder selection preserves paths and avoids filename ambiguity. It
selects `loud-import.json` ahead of `codec-import.json`, and never treats an
artwork sidecar as the main manifest. It packages loose files without
recompressing media, using ZIP64 and bounded read buffers. The server validates
the original paths and artwork. Import progress and artwork warnings are
visible in desktop and mobile web settings.

Server bundle limits are 64 GiB uploaded and declared expanded size, 100,000
entries, 32 MiB per JSON document, and 400 MiB per audio file. Browser loose
manifest inspection uses a 16 MiB limit. Reverse proxies may impose smaller
upload limits. For the combined 15.4 GB S2Y collection, use the CLI merge so
missing songs upload separately. Large-archive header tests do not establish
that a particular browser/proxy can upload a 15.4 GB ZIP.

Server exports include managed JPEG/PNG track and playlist originals with
regenerated descriptors. Existing MP3 embedded covers remain supported.
Optional `disc_number`, `explicit`, `identifiers`, and `source_urls` survive
local scans, server metadata, transfer, and export. These are additive API
fields; existing phone clients ignore unknown fields and continue reading
ordinary track/playlist artwork URLs. Audio MIME routing on desktop also
accepts all four import extensions: MP3, M4A, FLAC, and WAV. Actual decoding
still depends on the codec inside the file and the client platform.

The source `checksums.json`, `provenance.json`, and verification files are
retained with the bundle. Import does not run those documents as instructions
or treat their presence as proof that every audio file was verified. Artwork
descriptor hashes are independently checked.

Schema regression checks (with Python `jsonschema` installed):

```bash
python3 scripts/test-import-schema.py --bundle /path/to/bundle
```

Schemas: [main](codec-import.schema.json),
[playlist artwork](s2y-playlist-artwork.schema.json), and
[track artwork](s2y-track-artwork.schema.json).

Browser/server job reports additionally expose `added`, `existing`, `skipped`,
`playlist_adds`, and `liked`. `audio_restored` counts existing library entries
whose missing audio was repaired without replacing their metadata. Artwork
counters remain separate. A job marked `done` may still contain skipped files
or artwork diagnostics, so inspect its summary.
