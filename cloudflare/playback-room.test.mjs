import { describe, expect, test } from "bun:test";
import { PlaybackRoom } from "./src/worker.mjs";

describe("playback room", () => {
  test("returns an empty playback state before commands", async () => {
    const room = new PlaybackRoom(new MemoryState());
    const response = await room.fetch(new Request("https://codec.example.com/api/v3/playback"));
    const state = await response.json();

    expect(state.schema).toBe("loud.playback.v2");
    expect(state.state).toBe("stopped");
    expect(state.revision).toBe(0);
  });

  test("stores playback device presence", async () => {
    const room = new PlaybackRoom(new MemoryState());
    const put = await room.fetch(
      new Request("https://codec.example.com/api/v3/playback/devices/desktop", {
        method: "PUT",
        body: JSON.stringify({
          name: "Mac",
          track_fingerprint: "isrc:TEST",
          track_title: "A",
          is_playing: true,
          position_seconds: 12,
          volume: 0.8
        })
      })
    );
    const device = await put.json();
    const get = await room.fetch(new Request("https://codec.example.com/api/v3/playback/devices"));
    const devices = await get.json();

    expect(device.device_id).toBe("desktop");
    expect(device.name).toBe("Mac");
    expect(devices).toHaveLength(1);
    expect(devices[0].track_fingerprint).toBe("isrc:TEST");
  });

  test("deduplicates playback commands by command id", async () => {
    const room = new PlaybackRoom(new MemoryState());
    const command = {
      command_id: "cmd-1",
      kind: "play",
      device_id: "desktop",
      target_device_id: "desktop",
      track: {
        id: "track_a",
        path: "/music/a.mp3",
        fingerprint: "isrc:TEST"
      },
      position_seconds: 5
    };
    const first = await room.fetch(
      new Request("https://codec.example.com/api/v3/playback/commands", {
        method: "POST",
        body: JSON.stringify(command)
      })
    );
    const second = await room.fetch(
      new Request("https://codec.example.com/api/v3/playback/commands", {
        method: "POST",
        body: JSON.stringify(command)
      })
    );

    const firstState = await first.json();
    const secondState = await second.json();
    expect(firstState.revision).toBe(1);
    expect(secondState.revision).toBe(1);
    expect(secondState.track.fingerprint).toBe("isrc:TEST");
  });
});

class MemoryState {
  constructor() {
    this.storage = new MemoryStorage();
  }

  waitUntil() {}
}

class MemoryStorage {
  constructor() {
    this.values = new Map();
  }

  async get(key) {
    return clone(this.values.get(key));
  }

  async put(key, value) {
    this.values.set(key, clone(value));
  }
}

function clone(value) {
  return value === undefined ? undefined : structuredClone(value);
}
