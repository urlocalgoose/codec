# Codec Import Manifest v1

Use `loud.import.v1` when another program downloads or prepares audio files (MP3, M4A, FLAC, WAV) for Codec.

## Bundles (`.loud.zip`) — the preferred form

A bundle is the whole format in one file: a zip with the manifest at the
root as `codec-import.json` and every audio file under `files/`. No loose
files, no filesystem paths to resolve — the paths inside the zip are just
internal names the manifest points at. This is what "Share library" exports
(`library.loud.zip`) and what tools should produce when they can:

```
library.loud.zip
├── codec-import.json          loud.import.v1 manifest, base_path "files"
└── files/
    └── Artist/Album/Title.mp3 store-method (uncompressed) audio
```

Store the audio uncompressed — MP3s don't shrink and it keeps imports and
exports pure streaming. Codec's web app imports a bundle directly (Settings →
Import music, pick the zip); identity matching means importing someone
else's bundle only adds what you don't already have. Everything below about
manifests applies inside a bundle unchanged.

Codec keeps audio as normal media files, but it does not use duplicate files for app facts like liked songs or imported playlists. App truth lives in the selected music folder at `.loud/state.json`. New files are copied into `.loud/audio/Artist/Album/`, while songs that already exist are matched by identity and only get new playlist or liked references.

## Recommended Manifest

```json
{
  "schema": "loud.import.v1",
  "source": {
    "name": "s2y",
    "generated_at": "2026-06-25T19:30:00Z",
    "base_path": "files",
    "spotify_source": "liked-songs"
  },
  "tracks": [
    {
      "file": "Doja Cat/Planet Her/Woman.mp3",
      "title": "Woman",
      "artist": "Doja Cat",
      "album": "Planet Her",
      "album_artist": "Doja Cat",
      "track_number": 1,
      "disc_number": 1,
      "year": 2021,
      "duration_ms": 172626,
      "explicit": true,
      "liked": true,
      "playlists": ["Liked Songs"],
      "identifiers": {
        "isrc": "USRC12100543",
        "spotify_track_id": "spotify-track-id",
        "spotify_album_id": "spotify-album-id",
        "youtube_video_id": "youtube-video-id",
        "musicbrainz_recording_id": "musicbrainz-recording-id"
      },
      "source_urls": {
        "spotify": "https://open.spotify.com/track/spotify-track-id",
        "youtube": "https://www.youtube.com/watch?v=youtube-video-id"
      }
    }
  ],
  "playlists": [
    {
      "name": "Liked Songs",
      "mode": "append",
      "tracks": [
        {
          "identifiers": {
            "isrc": "USRC12100543"
          }
        }
      ]
    }
  ]
}
```

## Identity Rules

Codec chooses the canonical identity in this order:

1. `fingerprint`
2. `identifiers.isrc`
3. `identifiers.musicbrainz_recording_id`
4. `identifiers.spotify_track_id`
5. `identifiers.youtube_video_id`
6. normalized `title + artist + album`

The generated identity strings look like `isrc:USRC12100543`, `mbid:<id>`, `spotify:track:<id>`, and `youtube:<id>`.

`spotify_album_id` is stored as metadata, but it is not used as a track identity because album IDs are not song IDs.

## Playlist Refs

Back-compatible playlist refs still work:

```json
"tracks": ["Doja Cat/Planet Her/Woman.mp3"]
```

The stronger form is an identity ref:

```json
"tracks": [
  {
    "identifiers": {
      "spotify_track_id": "spotify-track-id"
    }
  }
]
```

You can also reference a direct Codec identity:

```json
"tracks": [
  {
    "fingerprint": "isrc:USRC12100543"
  }
]
```

## Downloader Rules

Write real audio files with normal tags whenever possible: title, artist, album, album artist, track number, disc number, year, genre, duration, and cover art.

Use stable relative file paths in `tracks[].file`. If `source.base_path` is set, Codec resolves files relative to that folder next to the manifest. Absolute paths work locally, but they are bad for sharing.

Prefer `identifiers` over `fingerprint` for downloader output. Keep `fingerprint` only when your tool already knows the exact Codec identity string it wants.

Use `liked: true` to mark the canonical song liked. Do not copy the song into a `Liked` folder.

Use `playlists[].mode: "replace"` only for sync-style imports where your program owns that playlist. Use `append` when you are handing Codec a bundle of songs to add.

## Importing From The Web App

The same manifest works in the browser (Settings → Import music) against a
sync server — no desktop app needed. Two differences from the desktop flow:

- A browser cannot follow `tracks[].file` paths on disk, so select the
  manifest **together with its audio files** in one file pick. Files are
  matched to manifest entries by file name (the last path segment of
  `tracks[].file`); `source.base_path` is ignored.
- Everything lands directly on the sync server via the track/playlist upsert
  endpoints instead of `.loud/` on disk. Identity rules, dedupe, `liked`,
  and playlist refs behave the same; `playlists[].mode` is treated as
  `append`.

Plain MP3s can also be picked without a manifest; identity then comes from
the normalized tag fallback, exactly like rule 6 above.

## Mixed New And Existing Imports

When Codec imports the manifest, each track lands in one of these buckets:

`new_tracks`: Codec copied the audio file into `.loud/audio`.

`existing_tracks`: Codec already had the song identity, so it did not copy the file.

`playlist_updates`: Codec added canonical song refs to playlists.

`liked_updates`: Codec marked canonical songs as liked.

`skipped_tracks`: The file was missing, not an MP3, or otherwise unreadable.

The key rule is simple: playlists and likes point at canonical songs, not file copies.
