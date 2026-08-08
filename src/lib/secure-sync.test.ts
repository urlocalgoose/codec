import { describe, expect, test } from "bun:test";
import {
  base64Url,
  canonicalRequest,
  canonicalSearch,
  cleanSecureDeviceId,
  createSecureSyncIdentity,
  deviceEnrollmentPayload,
  enrollSecureDevice,
  fetchSecureEnrolledDevices,
  fetchSecurePlaybackState,
  pushSecureLibrarySnapshot,
  signedRequest,
  streamSecurePlaybackEvents
} from "./secure-sync";
import type { Library, TrackReference } from "./types";

const library: Library = {
  root_path: "/music",
  scanned_at: 1,
  stats: {
    trackCount: 1,
    playlistCount: 0,
    likedCount: 0,
    artistCount: 1,
    albumCount: 1,
    durationSeconds: 1
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
      duration_seconds: 1,
      artwork_url: null,
      playlist_ids: [],
      added_at: 1,
      size_bytes: 1,
      is_liked: false,
      fingerprint: "isrc:TEST"
    }
  ]
};

describe("secure sync signing", () => {
  test("builds the same canonical query shape as the server", () => {
    const url = "https://codec.example.com/api/v3/library?z=2&a=2&a=1";
    const bodyHash = base64Url(new Uint8Array([1, 2, 3]));

    expect(canonicalSearch(url)).toBe("?a=1&a=2&z=2");
    expect(canonicalRequest("post", url, 123, "nonce", bodyHash)).toBe(
      `POST\n/api/v3/library\n?a=1&a=2&z=2\n123\nnonce\n${bodyHash}`
    );
  });

  test("cleans device ids for header use", () => {
    expect(cleanSecureDeviceId(" phone 1 / weird ")).toBe("phone_1___weird");
  });

  test("creates enrollment payloads without exporting the private key", async () => {
    const identity = await createSecureSyncIdentity("phone-1");
    const payload = await deviceEnrollmentPayload(identity, "iPhone", "ios");

    expect(payload.device_id).toBe("phone-1");
    expect(payload.public_key_jwk.kty).toBe("EC");
    expect(payload.public_key_jwk.crv).toBe("P-256");
    await expect(crypto.subtle.exportKey("jwk", identity.privateKey)).rejects.toThrow();
  });

  test("signs requests with raw P-256 signatures", async () => {
    const identity = await createSecureSyncIdentity("desktop");
    const request = await signedRequest(
      identity,
      "https://codec.example.com/api/v3/sync/push",
      {
        method: "PUT",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({ schema: "loud.sync.v3" })
      },
      123
    );

    expect(request.headers.get("x-loud-device-id")).toBe("desktop");
    expect(request.headers.get("x-loud-timestamp")).toBe("123");
    expect(request.headers.get("x-loud-nonce")?.length).toBeGreaterThan(8);
    expect(decodeBase64Url(request.headers.get("x-loud-signature") ?? "").byteLength).toBe(64);
  });

  test("pushes secure library snapshots to v3 with signed headers", async () => {
    const identity = await createSecureSyncIdentity("desktop");
    const requests: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      requests.push(request);
      return Response.json({ tracks_upserted: 1, playlists_upserted: 0 });
    }) as typeof fetch;

    const report = await pushSecureLibrarySnapshot("https://codec.example.com", identity, library, fetcher);
    const body = await requests[0].json();

    expect(report.tracks_upserted).toBe(1);
    expect(requests[0].url).toBe("https://codec.example.com/api/v3/sync/push");
    expect(requests[0].method).toBe("PUT");
    expect(requests[0].headers.get("x-loud-device-id")).toBe("desktop");
    expect(body.schema).toBe("loud.sync.v3");
  });

  test("enrolls devices with an Access-authenticated browser request", async () => {
    const identity = await createSecureSyncIdentity("desktop");
    const requests: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      requests.push(request);
      return Response.json({
        device_id: "desktop",
        name: "Mac",
        platform: "macos",
        created_at: 123
      });
    }) as typeof fetch;

    const device = await enrollSecureDevice("https://codec.example.com", identity, "Mac", "macos", fetcher);
    const body = await requests[0].json();

    expect(device.device_id).toBe("desktop");
    expect(requests[0].url).toBe("https://codec.example.com/api/v3/devices");
    expect(requests[0].credentials).toBe("include");
    expect(requests[0].headers.get("x-loud-signature")).toBeNull();
    expect(body.public_key_jwk.crv).toBe("P-256");
  });

  test("loads secure playback state from v3 with signed headers", async () => {
    const identity = await createSecureSyncIdentity("phone");
    const track: TrackReference = {
      id: "track_a",
      path: "/music/a.mp3",
      fingerprint: "isrc:TEST"
    };
    const requests: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      requests.push(request);
      return Response.json({
        schema: "loud.playback.v2",
        revision: 4,
        active_device_id: "phone",
        state: "playing",
        track,
        context: {
          playback_source: [track],
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
      });
    }) as typeof fetch;

    const state = await fetchSecurePlaybackState("https://codec.example.com", identity, fetcher);

    expect(requests[0].url).toBe("https://codec.example.com/api/v3/playback");
    expect(requests[0].headers.get("x-loud-device-id")).toBe("phone");
    expect(state?.track?.fingerprint).toBe("isrc:TEST");
  });

  test("loads enrolled devices from v3 with signed headers", async () => {
    const identity = await createSecureSyncIdentity("desktop");
    const requests: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      requests.push(request);
      return Response.json({
        devices: [
          {
            device_id: "phone",
            name: "iPhone",
            platform: "ios",
            created_at: 123
          }
        ]
      });
    }) as typeof fetch;

    const devices = await fetchSecureEnrolledDevices("https://codec.example.com", identity, fetcher);

    expect(requests[0].url).toBe("https://codec.example.com/api/v3/devices");
    expect(requests[0].headers.get("x-loud-device-id")).toBe("desktop");
    expect(devices[0].platform).toBe("ios");
  });

  test("streams signed playback events without EventSource", async () => {
    const identity = await createSecureSyncIdentity("desktop");
    const requests: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      requests.push(request);
      return new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(
              new TextEncoder().encode(
                "event: playback_state\n" +
                  "data: {\"revision\":9}\n\n" +
                  "event: devices\n" +
                  "data: [{\"device_id\":\"desktop\",\"name\":\"Mac\"}]\n\n"
              )
            );
            controller.close();
          }
        }),
        {
          status: 200,
          headers: {
            "Content-Type": "text/event-stream"
          }
        }
      );
    }) as typeof fetch;
    const events: unknown[] = [];

    await streamSecurePlaybackEvents("https://codec.example.com", identity, (event) => {
      events.push(event);
    }, { fetcher });

    expect(requests[0].url).toBe("https://codec.example.com/api/v3/playback/events");
    expect(requests[0].headers.get("Accept")).toBe("text/event-stream");
    expect(requests[0].headers.get("x-loud-device-id")).toBe("desktop");
    expect(events).toEqual([
      {
        type: "playback_state",
        playback_state: {
          active_device_id: null,
          clock: {
            position_seconds: 0,
            started_at_ms: null,
            stopped_at_ms: null,
            updated_at_ms: 0
          },
          context: {
            play_history: [],
            playback_index: 0,
            playback_source: [],
            queued_tracks: [],
            repeat: "off",
            shuffle: false
          },
          revision: 9,
          schema: "loud.playback.v2",
          server_time_ms: expect.any(Number),
          state: "stopped",
          track: null,
          volume: 0
        }
      },
      {
        type: "devices",
        devices: [
          {
            device_id: "desktop",
            name: "Mac"
          }
        ]
      }
    ]);
  });
});

function decodeBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}
