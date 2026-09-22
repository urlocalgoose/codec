import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { themes } from "./themes";
import { sampleSpectrumColors } from "./artwork-spectrum";
import { spectrumColorTable, spectrumPalette } from "./visualizer-palette";

const graphite = { bg: "#101312", accent: "#a7b0aa", text: "#eef2ed" };
const paper = { bg: "#e8e2d3", accent: "#2f7d5f", text: "#18140f" };
const sampled = ["rgb(17 53 201)", "rgb(223 71 32)", "rgb(236 202 111)", "rgb(38 124 76)"];
const sample = { cool: "rgb(17 53 201)", warm: "rgb(223 71 32)", deep: "rgb(10 10 20)", spectrum: sampled };
const inks = (palette: ReturnType<typeof spectrumPalette>) => [palette.cool, palette.mid, palette.warm, palette.hot];
const css = (color: readonly number[]) => `rgb(${color.map(value => Math.round(value * 255)).join(" ")})`;

function assertSourceOnly(theme: typeof graphite, art: typeof sample) {
  const palette = spectrumPalette(theme, art);
  const actual = inks(palette).map(css);
  for (const color of actual) expect(art.spectrum).toContain(color);
  for (const color of inks(palette)) expect(color.every(v => Number.isFinite(v) && v >= 0 && v <= 1)).toBe(true);
}

test("hard energy zones use only the four sampled cover colors with no blended midpoint", () => {
  const colors = spectrumColorTable(spectrumPalette(graphite, sample));
  expect(colors.ink).toHaveLength(256);
  expect(new Set(colors.ink)).toEqual(new Set(sampled));
  for (const [start, end] of [[0, 63], [64, 127], [128, 203], [204, 255]]) {
    expect(new Set(colors.ink.slice(start, end + 1)).size).toBe(1);
    if (start) expect(colors.ink[start]).not.toBe(colors.ink[start - 1]);
  }
});

test("theme changes can reorder cover colors but cannot replace or recolor them", () => {
  const dark = inks(spectrumPalette(graphite, sample)).map(css);
  const light = inks(spectrumPalette(paper, sample)).map(css);
  expect(light).toEqual([...dark].reverse());
  expect(new Set(dark)).toEqual(new Set(sampled));
  expect(new Set(light)).toEqual(new Set(sampled));
});

test("monochrome artwork uses that exact color on every band, even with a colorful theme", () => {
  for (const spectrum of [["rgb(36 166 78)"], ["rgb(0 0 0)"], ["rgb(255 255 255)"], ["rgb(112 112 112)"]]) {
    const art = { ...sample, spectrum };
    for (const theme of [graphite, paper]) expect(new Set(spectrumColorTable(spectrumPalette(theme, art)).ink)).toEqual(new Set(spectrum));
  }
});

test("two-color and grayscale covers keep their own colors rather than receiving a rainbow", () => {
  for (const spectrum of [sampled.slice(0, 2), ["rgb(16 16 16)", "rgb(80 80 80)", "rgb(160 160 160)", "rgb(240 240 240)"]]) {
    const colors = spectrumColorTable(spectrumPalette(graphite, { ...sample, spectrum }));
    expect(new Set(colors.ink)).toEqual(new Set(spectrum));
  }
});

test("a changed cover replaces every old ink and never uses warm/cool atmosphere approximations", () => {
  const green = { ...sample, spectrum: ["rgb(36 166 78)", "rgb(11 62 23)"] };
  const palette = spectrumPalette(graphite, green);
  expect(new Set(spectrumColorTable(palette).ink)).toEqual(new Set(green.spectrum));
  expect(palette.artwork).toBe(true);
});

test("missing artwork uses only theme colors; legacy samples use only their own extracted colors", () => {
  const missing = spectrumPalette(graphite, null);
  expect(spectrumColorTable(missing).background).toBe("rgb(16 19 18)");
  expect(missing.artwork).toBe(false);
  expect(new Set(spectrumColorTable(missing).ink)).toEqual(new Set(["rgb(167 176 170)", "rgb(238 242 237)"]));
  const { spectrum, ...legacy } = sample;
  expect(new Set(spectrumColorTable(spectrumPalette(graphite, legacy)).ink))
    .toEqual(new Set([legacy.deep, legacy.cool, legacy.warm]));
});

test("all themes retain exact sampled bytes for saturated, gray, dark, and pastel covers", () => {
  const cssText = readFileSync(new URL("../app.css", import.meta.url), "utf8");
  const sources = [sampled, ["rgb(9 17 34)", "rgb(41 28 17)"], ["rgb(215 193 183)", "rgb(174 202 201)"], ["rgb(98 98 98)"]];
  for (const theme of themes) {
    const block = cssText.match(new RegExp(`\\[data-theme="${theme.id}"\\][^{]*\\{([^}]+)`))?.[1];
    expect(block).toBeDefined();
    const token = (name: string) => block!.match(new RegExp(`--color-${name}:\\s*(#[\\da-f]+)`))![1];
    const tokens = { bg: token("bg"), accent: token("accent"), text: token("text") };
    for (const spectrum of sources) assertSourceOnly(tokens, { ...sample, spectrum });
  }
});

test("pixel sampling through to the complete render lookup never adds a color", () => {
  const source = [[19, 31, 127], [200, 53, 22], [210, 183, 96]];
  const spectrum = sampleSpectrumColors(source.flatMap(color => Array.from({ length: 768 }, () => color.map(value => value / 255))));
  const table = spectrumColorTable(spectrumPalette(paper, { ...sample, spectrum }));
  const allowed = source.map(color => `rgb(${color.join(" ")})`);
  for (const color of table.ink) expect(allowed).toContain(color);
});

test("opacity preserves fine intensity detail and silence without altering the source ink", () => {
  const { alpha } = spectrumColorTable(spectrumPalette(graphite, sample));
  expect(alpha).toHaveLength(256);
  expect(alpha[0]).toBe(0);
  expect(alpha[255]).toBe(1);
  expect(alpha[128]).toBeGreaterThan(.65);
  expect(alpha[64]).toBeGreaterThan(.45);
  for (let byte = 1; byte < 256; byte++) expect(alpha[byte]).toBeGreaterThan(alpha[byte - 1]);
});
