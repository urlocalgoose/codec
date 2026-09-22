import { describe, expect, test } from "bun:test";
import { createPlaybackAudioSession } from "./audio-session";

describe("music audio-session ownership", () => {
  test("claims playback once and restores the prior policy on transfer", () => {
    let type = "auto";
    const changes: string[] = [];
    const session = { get type() { return type; }, set type(value: string) { changes.push(value); type = value; } };
    const music = createPlaybackAudioSession(() => session);
    // Merely opening a remote controller must not alter phone audio focus.
    expect(changes).toEqual([]);
    music.begin(); music.begin(); music.begin();
    expect(type).toBe("playback");
    expect(changes).toEqual(["playback"]);
    music.release(); music.release();
    expect(changes).toEqual(["playback", "auto"]);
    music.begin(); music.release();
    expect(type).toBe("auto");
  });

  test("teardown preserves another audio feature's newer policy", () => {
    const session = { type: "ambient" };
    const music = createPlaybackAudioSession(() => session);
    music.begin();
    session.type = "play-and-record";
    music.release();
    expect(session.type).toBe("play-and-record");
  });

  test("an unsupported or disabled API never prevents HTML audio playback", () => {
    for (const read of [() => undefined, () => { throw new Error("Unavailable"); }]) {
      const music = createPlaybackAudioSession(read);
      expect(() => { music.begin(); music.release(); }).not.toThrow();
      expect(music.isInterrupted()).toBe(false);
    }
    const denied = createPlaybackAudioSession(() => ({
      get type() { return "auto"; }, set type(_value: string) { throw new Error("Denied"); }
    }));
    expect(() => { denied.begin(); denied.release(); }).not.toThrow();
  });

  test("an OS interruption is distinct from an idle audio session", () => {
    const session = { type: "auto", state: "interrupted" };
    const music = createPlaybackAudioSession(() => session);
    expect(music.isInterrupted()).toBe(true);
    session.state = "inactive";
    expect(music.isInterrupted()).toBe(false);
  });
});
