import { expect, test } from "bun:test";
import { SpectroSampler, SPECTRO_BANDS } from "./visualizer";

test("sampling pauses without erasing history and resumes with a single frame loop", () => {
  const originalRequest = globalThis.requestAnimationFrame;
  const originalCancel = globalThis.cancelAnimationFrame;
  const frames = new Map<number, FrameRequestCallback>();
  let nextId = 0, reads = 0;
  globalThis.requestAnimationFrame = callback => { frames.set(++nextId,callback); return nextId; };
  globalThis.cancelAnimationFrame = id => { frames.delete(id); };
  const analyser = {frequencyBinCount:256,getByteFrequencyData(data:Uint8Array){reads++;data.fill(100);}} as unknown as AnalyserNode;
  try {
    const sampler = new SpectroSampler(analyser,10);
    expect(reads).toBe(1);
    expect(frames.size).toBe(1);
    sampler.start();
    expect(reads).toBe(1);
    const history = new Uint8Array(SPECTRO_BANDS);
    sampler.column(0,history);
    sampler.stop();
    expect(frames.size).toBe(0);
    expect(sampler.count).toBe(1);
    const retained = new Uint8Array(SPECTRO_BANDS);
    sampler.column(0,retained);
    expect(retained).toEqual(history);
    sampler.start();
    expect(sampler.count).toBe(2);
    expect(frames.size).toBe(1);
    sampler.stop();
    sampler.stop();
    expect(frames.size).toBe(0);
  } finally {
    globalThis.requestAnimationFrame = originalRequest;
    globalThis.cancelAnimationFrame = originalCancel;
  }
});

function withSampler(run: (sampler: SpectroSampler, frame: () => void) => void, capacity = 10) {
  const originalRequest = globalThis.requestAnimationFrame;
  const originalCancel = globalThis.cancelAnimationFrame;
  const frames = new Map<number, FrameRequestCallback>();
  let nextId = 0;
  globalThis.requestAnimationFrame = callback => { frames.set(++nextId, callback); return nextId; };
  globalThis.cancelAnimationFrame = id => { frames.delete(id); };
  const analyser = { frequencyBinCount: 256, getByteFrequencyData(data: Uint8Array) { data.fill(255); } } as unknown as AnalyserNode;
  const sampler = new SpectroSampler(analyser, capacity);
  const frame = () => {
    const [id, callback] = [...frames.entries()][0];
    frames.delete(id);
    callback(0);
  };
  try { run(sampler, frame); }
  finally { sampler.stop(); globalThis.requestAnimationFrame = originalRequest; globalThis.cancelAnimationFrame = originalCancel; }
}

const solidColors = (ink: string, background: string) => ({
  background, ink: Array<string>(256).fill(ink), alpha: Array.from({ length: 256 }, (_, byte) => Math.pow(byte / 255, .55))
});

test("recorded columns retain old song ink and background as new song columns arrive", () => {
  withSampler((sampler, frame) => {
    sampler.setColors(solidColors("rgb(230 20 30)", "rgb(24 8 10)"));
    frame(); frame();
    const old = sampler.colorsAt(1);
    expect(sampler.colorsAt(2)).toBe(old);
    sampler.setColors(solidColors("rgb(20 180 40)", "rgb(8 24 10)"));
    expect(sampler.count).toBe(3);
    frame(); frame();
    expect(sampler.colorsAt(1)).toBe(old);
    expect(sampler.colorsAt(2)).toBe(old);
    expect(sampler.colorsAt(3).ink[255]).toBe("rgb(20 180 40)");
    expect(sampler.colorsAt(3).background).toBe("rgb(8 24 10)");
    expect(old.ink[255]).toBe("rgb(230 20 30)");
    expect(old.background).toBe("rgb(24 8 10)");
  });
});

test("late artwork affects only new columns and does not recolor the loading interval", () => {
  withSampler((sampler, frame) => {
    const first = sampler.colorsAt(0);
    sampler.setColors(solidColors("rgb(160 160 160)", "rgb(16 16 16)"));
    frame();
    const loading = sampler.colorsAt(1);
    sampler.setColors(solidColors("rgb(30 60 200)", "rgb(8 10 24)"));
    frame();
    expect(sampler.colorsAt(0)).toBe(first);
    expect(sampler.colorsAt(1)).toBe(loading);
    expect(sampler.colorsAt(2).ink[255]).toBe("rgb(30 60 200)");
  });
});

test("history owns immutable palettes while views are absent and across pause/resume", () => {
  withSampler((sampler, frame) => {
    const red = solidColors("rgb(240 0 0)", "rgb(24 0 0)");
    sampler.setColors(red); frame();
    red.ink.fill("rgb(0 240 0)"); red.alpha.fill(0); red.background = "rgb(0 24 0)";
    const retained = sampler.colorsAt(1);
    expect(retained.ink[255]).toBe("rgb(240 0 0)");
    expect(retained.alpha[255]).toBe(1);
    expect(retained.background).toBe("rgb(24 0 0)");
    sampler.stop();
    sampler.setColors(solidColors("rgb(0 0 240)", "rgb(0 0 24)"));
    expect(sampler.count).toBe(2);
    expect(sampler.colorsAt(1)).toBe(retained);
    sampler.start();
    expect(sampler.colorsAt(2).ink[255]).toBe("rgb(0 0 240)");
    expect(sampler.colorsAt(1)).toBe(retained);
  });
});

test("ring wrap retains matching bounded appearances and reuses one table for a run", () => {
  withSampler((sampler, frame) => {
    sampler.setColors(solidColors("rgb(220 20 20)", "rgb(20 2 2)"));
    for (let i = 0; i < 3; i++) frame();
    const red = sampler.colorsAt(3);
    sampler.setColors(solidColors("rgb(20 20 220)", "rgb(2 2 20)"));
    frame(); frame();
    expect(sampler.oldestIndex).toBe(2);
    expect(sampler.colorsAt(2)).toBe(red);
    expect(sampler.colorsAt(3)).toBe(red);
    expect(sampler.colorsAt(4)).toBe(sampler.colorsAt(5));
    expect(() => sampler.colorsAt(1)).toThrow(RangeError);
    expect(() => sampler.colorsAt(6)).toThrow(RangeError);
    for (let i = 0; i < 12; i++) frame();
    const blue = sampler.colorsAt(sampler.oldestIndex);
    for (let index = sampler.oldestIndex; index < sampler.count; index++) expect(sampler.colorsAt(index)).toBe(blue);
    expect(() => sampler.colorsAt(3)).toThrow(RangeError);
  }, 4);
});

test("appearance notifications redraw without sampling or mutating retained columns", () => {
  withSampler((sampler, frame) => {
    const first = sampler.colorsAt(0);
    let changes = 0;
    const remove = sampler.subscribeColors(() => { changes++; });
    const colors = solidColors("rgb(0 210 40)", "rgb(0 20 4)");
    sampler.setColors(colors);
    sampler.setColors(solidColors("rgb(0 210 40)", "rgb(0 20 4)"));
    expect(changes).toBe(1);
    expect(sampler.count).toBe(1);
    expect(sampler.colorsAt(0)).toBe(first);
    frame(); expect(changes).toBe(1);
    remove();
    sampler.setColors(solidColors("rgb(200 20 20)", "rgb(20 2 2)"));
    expect(changes).toBe(1);
  });
});
