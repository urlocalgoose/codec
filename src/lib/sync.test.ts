import { describe, expect, test } from "bun:test";
import {
  derivedPlaybackPosition,
  fetchActivePlayback,
  fetchRemoteLibrary,
  fetchPlaybackStateV2,
  fetchPlaybackDevices,
  normalizeLibrary,
  normalizeServerUrl,
  playbackEventsUrl,
  playbackEventsV2Url,
  pushLibrarySnapshot,
  saveRemotePlaybackSession,
  sendPlaybackCommandV2,
  securePlaybackEventsUrl,
  secureTrackAudioUrl,
  trackAudioUrl,
  transferPlayback,
  updatePlaybackDevice,
  validateSyncServer
} from "./sync";
import type { Library, TrackReference } from "./types";

const library: Library = {
  root_path: "/music",
  scanned_at: 1,
  stats: {
    trackCount: 1,
    playlistCount: 0,
    likedCount: 1,
    artistCount: 1,
    albumCount: 1,
    durationSeconds: 95
  },
  artists: [],
  albums: [],
  playlists: [],
  tracks: [
    {
      id: "track_a",
      path: "/music/a.mp3",
      file_name: "a.mp3",
      title: "A",
      artist: "Ada",
      album: "Compiler Songs",
      album_artist: null,
      genre: null,
      year: null,
      track_number: null,
      duration_seconds: 95,
      artwork_url: null,
      playlist_ids: [],
      added_at: 1,
      size_bytes: 10,
      is_liked: true,
      fingerprint: "isrc:TEST"
    }
  ]
};

describe("sync client helpers", () => {
  test("normalizes server urls and builds encoded audio urls", () => {
    expect(normalizeServerUrl("localhost:8787/")).toBe("http://localhost:8787");
    expect(normalizeServerUrl("https://music.test///")).toBe("https://music.test");
    expect(trackAudioUrl("localhost:8787", "isrc:US/TEST")).toBe(
      "http://localhost:8787/api/v1/tracks/isrc%3AUS%2FTEST/audio"
    );
    expect(secureTrackAudioUrl("https://codec.example.com", "isrc:US/TEST")).toBe(
      "https://codec.example.com/api/v3/tracks/isrc%3AUS%2FTEST/audio"
    );
    expect(playbackEventsUrl("localhost:8787/")).toBe(
      "http://localhost:8787/api/v1/playback/events"
    );
    expect(playbackEventsV2Url("localhost:8787/")).toBe(
      "http://localhost:8787/api/v2/playback/events"
    );
    expect(securePlaybackEventsUrl("https://codec.example.com/")).toBe(
      "https://codec.example.com/api/v3/playback/events"
    );
  });

  test("explains when the pasted URL is the web app dev server", async () => {
    const fetcher = (async (_input: RequestInfo | URL, _init?: RequestInit) =>
      new Response(null, { status: 404 })) as typeof fetch;

    await expect(validateSyncServer("http://100.103.211.30:1420", fetcher)).rejects.toThrow(
      "web app dev server"
    );
    await expect(fetchRemoteLibrary("http://100.103.211.30:1420", fetcher)).rejects.toThrow(
      "Use http://100.103.211.30:8787 instead"
    );
  });

  test("normalizes null remote arrays from an empty sync server", () => {
    const normalized = normalizeLibrary({
      root_path: "loud://sync-server",
      scanned_at: 1,
      artists: null,
      albums: null,
      playlists: null,
      tracks: null
    } as unknown as Partial<Library>);

    expect(normalized.artists).toEqual([]);
    expect(normalized.albums).toEqual([]);
    expect(normalized.playlists).toEqual([]);
    expect(normalized.tracks).toEqual([]);
    expect(normalized.stats.trackCount).toBe(0);
  });

  test("pushes a library snapshot with the Loud sync schema", async () => {
    const requests: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(new Request(input, init));
      return Response.json({
        tracks_upserted: 1,
        playlists_upserted: 0,
        sessions_upserted: 0
      });
    }) as typeof fetch;

    const report = await pushLibrarySnapshot("server.test", "device-a", library, fetcher);
    const request = requests[0];
    const body = await request.json();

    expect(report.tracks_upserted).toBe(1);
    expect(request.url).toBe("http://server.test/api/v1/sync/push");
    expect(body.schema).toBe("loud.sync.v1");
    expect(body.device_id).toBe("device-a");
    expect(body.library.tracks[0].fingerprint).toBe("isrc:TEST");
  });

  test("saves playback sessions by device", async () => {
    const requests: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(new Request(input, init));
      return new Response(null, { status: 204 });
    }) as typeof fetch;

    await saveRemotePlaybackSession(
      "server.test",
      "phone 1",
      { schema: "loud.playback.v1", current_time: 12 },
      123,
      fetcher
    );

    const request = requests[0];
    const body = await request.json();
    expect(request.url).toBe("http://server.test/api/v1/playback-session/phone%201");
    expect(body.saved_at).toBe(123);
    expect(body.session.current_time).toBe(12);
  });

  test("updates playback devices and transfers active playback", async () => {
    const requests: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      requests.push(request);

      if (request.url.endsWith("/api/v1/playback/devices")) {
        return Response.json([
          {
            device_id: "phone",
            name: "iPhone",
            track_id: "track_a",
            track_fingerprint: "isrc:TEST",
            track_title: "A",
            is_playing: true,
            position_seconds: 9,
            volume: 0.8,
            updated_at: 456
          }
        ]);
      }

      if (request.url.endsWith("/api/v1/playback/active")) {
        return Response.json({
          device_id: "phone",
          track_id: "track_a",
          track_fingerprint: "isrc:TEST",
          track_title: "A",
          is_playing: true,
          position_seconds: 9,
          volume: 0.8,
          updated_at: 456
        });
      }

      if (request.method === "PUT" && request.url.endsWith("/api/v1/playback/transfer")) {
        return Response.json({
          device_id: "phone",
          track_id: "track_a",
          track_fingerprint: "isrc:TEST",
          track_title: "A",
          is_playing: true,
          position_seconds: 9,
          volume: 0.8,
          updated_at: 456
        });
      }

      return new Response(null, { status: 204 });
    }) as typeof fetch;

    await updatePlaybackDevice(
      "server.test",
      {
        device_id: "desktop",
        name: "Desktop",
        track_id: "track_a",
        track_fingerprint: "isrc:TEST",
        track_title: "A",
        is_playing: false,
        position_seconds: 4,
        volume: 0.7,
        updated_at: 123
      },
      fetcher
    );
    const devices = await fetchPlaybackDevices("server.test", fetcher);
    const active = await fetchActivePlayback("server.test", fetcher);
    const transferred = await transferPlayback(
      "server.test",
      {
        device_id: "phone",
        track_id: "track_a",
        track_fingerprint: "isrc:TEST",
        track_title: "A",
        is_playing: true,
        position_seconds: 9,
        volume: 0.8
      },
      fetcher
    );

    expect(requests[0].url).toBe("http://server.test/api/v1/playback/devices/desktop");
    expect((await requests[0].json()).name).toBe("Desktop");
    expect(devices[0].device_id).toBe("phone");
    expect(active?.device_id).toBe("phone");
    expect(transferred.track_fingerprint).toBe("isrc:TEST");
  });

  test("loads and commands playback v2 state", async () => {
    const requests: Request[] = [];
    const trackRef: TrackReference = {
      id: "track_a",
      path: "/music/a.mp3",
      fingerprint: "isrc:TEST"
    };
    const state = {
      schema: "loud.playback.v2",
      revision: 2,
      active_device_id: "phone",
      state: "playing",
      track: trackRef,
      context: {
        playback_source: [trackRef],
        playback_index: 0,
        queued_tracks: null,
        play_history: null,
        shuffle: false,
        repeat: "off"
      },
      clock: {
        position_seconds: 12,
        started_at_ms: 1000,
        stopped_at_ms: null,
        updated_at_ms: 1000
      },
      volume: 0.8,
      server_time_ms: 1000
    };
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      requests.push(request);
      return Response.json(state);
    }) as typeof fetch;

    const loaded = await fetchPlaybackStateV2("server.test", fetcher);
    const commanded = await sendPlaybackCommandV2(
      "server.test",
      {
        command_id: "cmd-1",
        kind: "play",
        device_id: "desktop",
        target_device_id: "phone",
        track: trackRef
      },
      fetcher
    );

    expect(requests[0].url).toBe("http://server.test/api/v2/playback");
    expect(requests[1].url).toBe("http://server.test/api/v2/playback/commands");
    expect((await requests[1].json()).target_device_id).toBe("phone");
    expect(loaded?.context.queued_tracks).toEqual([]);
    expect(commanded.track?.fingerprint).toBe("isrc:TEST");
  });

  test("derives playback v2 position from a stored clock offset", () => {
    const position = derivedPlaybackPosition(
      {
        schema: "loud.playback.v2",
        revision: 1,
        active_device_id: "desktop",
        state: "playing",
        track: null,
        context: {
          playback_source: [],
          playback_index: 0,
          queued_tracks: [],
          play_history: [],
          shuffle: false,
          repeat: "off"
        },
        clock: {
          position_seconds: 10,
          started_at_ms: 1000,
          stopped_at_ms: null,
          updated_at_ms: 1000
        },
        volume: 0.8,
        server_time_ms: 1000
      },
      4000,
      -1000
    );

    expect(position).toBe(12);
  });
});
