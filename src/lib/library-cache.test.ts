import { describe, expect, test } from "bun:test";
import { stripAccessTokens } from "./library-cache";
import type { Library } from "./types";

describe("library cache", () => {
  test("strips short-lived access tokens from cached media URLs", () => {
    const library = {
      root_path: "loud://sync-server",
      scanned_at: 1,
      stats: {
        trackCount: 1,
        playlistCount: 1,
        likedCount: 0,
        artistCount: 1,
        albumCount: 1,
        durationSeconds: 10
      },
      artists: [],
      albums: [],
      playlists: [
        {
          id: "pl",
          name: "Mix",
          path: "",
          track_ids: ["t"],
          is_liked: false,
          artwork_url: "https://host/api/v1/playlists/pl/artwork?v=5&access_token=stream_abc"
        }
      ],
      tracks: [
        {
          id: "t",
          path: "/a.mp3",
          file_name: "a.mp3",
          title: "A",
          artist: "B",
          album: "C",
          album_artist: null,
          genre: null,
          year: null,
          track_number: null,
          duration_seconds: 10,
          artwork_url: "https://host/api/v1/tracks/f/artwork?access_token=stream_abc",
          playlist_ids: [],
          added_at: null,
          size_bytes: 1,
          is_liked: false,
          fingerprint: "f"
        }
      ]
    } satisfies Library;

    const stripped = stripAccessTokens(library);

    expect(stripped.tracks[0].artwork_url).toBe("https://host/api/v1/tracks/f/artwork");
    expect(stripped.playlists[0].artwork_url).toBe("https://host/api/v1/playlists/pl/artwork?v=5");
    // The original object is untouched.
    expect(library.tracks[0].artwork_url).toContain("access_token");
  });
});
