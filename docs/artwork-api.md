# Artwork API compatibility

Track and playlist covers keep their existing endpoints and schema:

- `PUT /api/v1/tracks/{fingerprint}/artwork`
- `PUT /api/v1/playlists/{id}/artwork`
- `GET` / `HEAD` at the same paths
- `DELETE /api/v1/playlists/{id}/artwork` remains an explicit cover deletion.

New HTTP uploads accept valid **JPEG and PNG** originals up to **12 MiB
(12,582,912 bytes)**, **8,192 pixels per edge**, and **16,777,216 total pixels**.
Dimensions are checked before full decoding; corrupt/truncated image data is
rejected before changing any existing cover. The original bytes, quality, and
PNG transparency are preserved. The actual image format determines responses,
so a legacy caller's stale but syntactically valid MIME header does not cause
the server to mislabel PNG data as JPEG. Invalid uploads return 400; size or
dimension limits return 413. New GIF/WebP uploads are rejected explicitly.

Ordinary PUT retains its existing replacement behavior and 204 response.
Additive importers may send `If-None-Match: *`: a missing cover is created
atomically, while an existing cover returns 412 without changes. Importers
supporting older server binaries must still HEAD first, because older servers
ignore this conditional header. HEAD followed by PUT alone cannot provide an
atomic no-overwrite guarantee on those older binaries.

GET/HEAD report the actual MIME type with `nosniff`, private revalidation, and
an ETag. Legacy GIF/WebP covers previously written by embedded-art imports stay
readable with their correct MIME types. Files retain the old internal `.jpg`
storage paths for compatibility; the extension is not used to infer MIME.

Both track and playlist `artwork_url` values include a file-mtime `?v=` value,
so a replacement image invalidates native/web image caches. The existing
optional JSON fields and endpoint URLs remain compatible with installed
clients. Metadata updates without artwork, playlist renames, and server
restarts preserve covers. Moving a data directory still uses the canonical
artwork path as a fallback when the stored absolute track path is stale.

Verification:

```sh
cd sync-server
go test ./...
go test -race ./internal/server -run 'TestArtwork|TestPlaylistArtwork|TestSyncPrivateMediaAndCoverVersions' -count=1
```

These code changes do not require an iPhone update. They require a server
binary update to become active; a JPEG-only additive import can continue using
the existing server API without restarting it.
