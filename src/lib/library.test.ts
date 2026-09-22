import { describe, expect, test } from "bun:test";
import {
  artistCovers,
  foreignTrackFromReference,
  createQueue,
  findTrackByReference,
  formatDuration,
  libraryStats,
  playbackQueue,
  searchTracks,
  sortTracks,
  trackReference,
  tracksFromReferences,
  tracksForMobileCollection
} from "./library";
import type { Library, Track } from "./types";

const baseTrack: Track = {
  id: "track-a",
  path: "/music/Mix/A.mp3",
  file_name: "A.mp3",
  title: "The First Track",
  artist: "Ada",
  album: "Compiler Songs",
  album_artist: null,
  genre: "Electronic",
  year: 2026,
  track_number: 1,
  duration_seconds: 95,
  artwork_url: null,
  playlist_ids: ["playlist-mix", "playlist-liked"],
  added_at: 100,
  size_bytes: 10,
  is_liked: true,
  fingerprint: "same"
};

const tracks: Track[] = [
  baseTrack,
  {
    ...baseTrack,
    id: "track-b",
    path: "/music/Mix/B.mp3",
    file_name: "B.mp3",
    title: "Zero State",
    artist: "Grace",
    album: "Debugging Hearts",
    track_number: 2,
    duration_seconds: 240,
    added_at: 300,
    is_liked: false,
    fingerprint: "other"
  }
];

const library: Library = {
  root_path: "/music",
  scanned_at: 1,
  stats: {
    trackCount: 2,
    playlistCount: 1,
    likedCount: 1,
    artistCount: 2,
    albumCount: 2,
    durationSeconds: 335
  },
  artists: [],
  albums: [],
  playlists: [
    {
      id: "playlist-liked",
      name: "Liked",
      path: "/music/Liked",
      track_ids: ["track-a"],
      is_liked: true
    },
    {
      id: "playlist-mix",
      name: "Mix",
      path: "/music/Mix",
      track_ids: ["track-a", "track-b"],
      is_liked: false
    }
  ],
  tracks
};

describe("library helpers", () => {
  test("mobile albums match compilation buckets and native track order", () => {
    const compilation = {
      ...library,
      tracks: [
        { ...baseTrack, id: "second", artist: "Grace", album_artist: "Various Artists", album: "Mix", track_number: 2 },
        { ...baseTrack, id: "first", artist: "Ada", album_artist: "VARIOUS ARTISTS", album: "MIX", track_number: 1 },
        { ...baseTrack, id: "unnumbered", artist: "Third", album_artist: "Various Artists", album: "Mix", track_number: null },
        { ...baseTrack, id: "other", artist: "Ada", album_artist: null, album: "Mix", track_number: 1 }
      ]
    };
    expect(tracksForMobileCollection(compilation, { kind: "album", title: "Mix", artist: "Various Artists" }).map((track) => track.id)).toEqual(["first", "second", "unnumbered"]);
    expect(tracksForMobileCollection(compilation, { kind: "artist", title: "Ada" }).map((track) => track.id)).toEqual(["first", "other"]);
    expect(compilation.tracks[0].id).toBe("second");
  });

  test("mobile albums fall back to track artist for empty album-artist tags", () => {
    const emptyTag = { ...library, tracks: [{ ...baseTrack, album_artist: "" }] };
    expect(tracksForMobileCollection(emptyTag, { kind: "album", title: baseTrack.album, artist: "ADA" })).toEqual(emptyTag.tracks);
    expect(tracksForMobileCollection(null, { kind: "album", title: "missing", artist: "nobody" })).toEqual([]);
  });

  test("searches across title artist album genre and filename", () => {
    expect(searchTracks(tracks, "ada compiler")).toEqual([tracks[0]]);
    expect(searchTracks(tracks, "debug hearts")).toEqual([tracks[1]]);
    expect(searchTracks(tracks, "b.mp3")).toEqual([tracks[1]]);
  });

  test("sorts without mutating the original track list", () => {
    const sorted = sortTracks(tracks, "added");

    expect(sorted.map((track) => track.id)).toEqual(["track-b", "track-a"]);
    expect(tracks.map((track) => track.id)).toEqual(["track-a", "track-b"]);
  });

  test("creates a queue with the selected track first", () => {
    expect(createQueue(tracks, "track-b").map((track) => track.id)).toEqual(["track-b", "track-a"]);
  });

  test("builds a Spotify-style queue with manual tracks before source playback resumes", () => {
    expect(playbackQueue(tracks[0], [], [tracks[0], tracks[1]], 0).map((track) => track.id)).toEqual([
      "track-a",
      "track-b"
    ]);
  });

  test("formats durations for player and table surfaces", () => {
    expect(formatDuration(95)).toBe("1:35");
    expect(formatDuration(3661)).toBe("1:01:01");
    expect(formatDuration(null)).toBe("--:--");
  });

  test("restores tracks from stable references after a rescan", () => {
    const movedTrack = {
      ...tracks[0],
      path: "/music/Renamed/A.mp3",
      title: "Updated Title"
    };
    const rescannedLibrary = {
      ...library,
      tracks: [movedTrack, tracks[1]]
    };

    expect(findTrackByReference(rescannedLibrary, trackReference(tracks[0]))).toEqual(movedTrack);
    expect(
      tracksFromReferences(rescannedLibrary, [
        trackReference(tracks[1]),
        trackReference(tracks[1]),
        { id: "missing", path: "/nope.mp3", fingerprint: "missing" }
      ])
    ).toEqual([tracks[1], tracks[1]]);
  });

  test("maps each artist to their first available artwork", () => {
    const withArt = {
      ...library,
      tracks: [
        { ...tracks[0], artwork_url: null },
        { ...tracks[0], id: "track-a2", path: "/music/Mix/A2.mp3", artwork_url: "/art/ada.jpg" },
        { ...tracks[1], artist: "grace ", artwork_url: "/art/grace.jpg" }
      ]
    };

    const covers = artistCovers(withArt);

    expect(covers.get("Ada")).toBe("/art/ada.jpg");
    // Keyed by the first-seen display name, whitespace-insensitively.
    expect(covers.get("grace ")).toBe("/art/grace.jpg");
    expect(artistCovers(null).size).toBe(0);
  });

  test("summarizes library counts", () => {
    expect(libraryStats(library)).toMatchObject({
      trackCount: 2,
      playlistCount: 1,
      likedCount: 1,
      artistCount: 2,
      albumCount: 2,
      durationSeconds: 335
    });
  });
});

describe("foreign aux tracks", () => {
  test("a reference with a granted media URL synthesizes a playable track", () => {
    const track = foreignTrackFromReference({
      id: "track_abc",
      path: "aux://abc",
      fingerprint: "abc",
      title: "Their Song",
      artist: "Their Artist",
      media_url: "https://their-server/api/v1/tracks/abc/audio?access_token=grant_x",
      artwork_url: "https://their-server/api/v1/tracks/abc/artwork?access_token=grant_x"
    });

    expect(track?.title).toBe("Their Song");
    expect(track?.media_url).toContain("grant_x");
    expect(track?.fingerprint).toBe("abc");
  });

  test("a plain local reference does not synthesize anything", () => {
    expect(foreignTrackFromReference({ id: "t", path: "/a.mp3", fingerprint: "f" })).toBeNull();
  });

  test("re-queueing a foreign track keeps its grant in the reference", () => {
    const track = foreignTrackFromReference({
      id: "track_abc",
      path: "aux://abc",
      fingerprint: "abc",
      media_url: "https://their-server/audio"
    });
    expect(trackReference(track!)).toMatchObject({ media_url: "https://their-server/audio" });
  });
});
