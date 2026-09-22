import { expect, test } from "bun:test";
import { sampleSpectrumColors } from "./artwork-spectrum";

type RGB = [number, number, number];
const css = (color: RGB) => `rgb(${color.join(" ")})`;
const points = (colors: RGB[], counts = colors.map(() => 576)) =>
  colors.flatMap((color, i) => Array.from({ length: counts[i] }, () => color.map(channel => channel / 255)));

test("spectrum representatives are actual cover pixels, never cluster averages or complements", () => {
  const colors: RGB[] = [[17, 53, 201], [223, 71, 32], [236, 202, 111], [38, 124, 76]];
  const actual = sampleSpectrumColors(points(colors));
  expect(new Set(actual)).toEqual(new Set(colors.map(css)));
  expect(actual).toHaveLength(4);
});

test("a bucket representative occurs in the image even when its mean does not", () => {
  const colors: RGB[] = [[40, 100, 180], [46, 106, 186]];
  const actual = sampleSpectrumColors(points(colors));
  expect(actual).toEqual([css(colors[0])]);
  expect(actual).not.toContain("rgb(43 103 183)");
});

test("one-color and two-color covers never gain unrelated hues", () => {
  for (const color of [[36, 166, 78], [0, 0, 0], [255, 255, 255], [93, 101, 112]] as RGB[]) {
    expect(sampleSpectrumColors(points([color]))).toEqual([css(color)]);
  }
  const colors: RGB[] = [[208, 154, 102], [23, 73, 64]];
  expect(new Set(sampleSpectrumColors(points(colors)))).toEqual(new Set(colors.map(css)));
});

test("grayscale and muted artwork retain their original channel values", () => {
  const gray: RGB[] = [[16, 16, 16], [80, 80, 80], [160, 160, 160], [240, 240, 240]];
  const pastel: RGB[] = [[220, 160, 185], [178, 202, 204], [202, 194, 170], [133, 142, 145]];
  for (const colors of [gray, pastel]) {
    const actual = sampleSpectrumColors(points(colors));
    expect(actual).toHaveLength(4);
    expect(new Set(actual)).toEqual(new Set(colors.map(css)));
  }
});

test("isolated color noise does not dominate a supported cover palette", () => {
  const colors: RGB[] = [[92, 88, 80], [154, 144, 128], [255, 0, 255]];
  expect(new Set(sampleSpectrumColors(points(colors, [1500, 803, 1]))))
    .toEqual(new Set(colors.slice(0, 2).map(css)));
});

test("small textured cover accents survive beside a large dark background", () => {
  const accents: RGB[] = [[204, 104, 40], [208, 108, 44], [212, 112, 48], [216, 116, 52], [220, 120, 56], [202, 102, 38]];
  const source = points([[8, 10, 8], [218, 221, 212], [48, 96, 40]], [1800, 250, 248])
    .concat(points(accents, accents.map(() => 1)));
  const actual = sampleSpectrumColors(source);
  expect(actual).toHaveLength(4);
  expect(actual.some(color => accents.map(css).includes(color))).toBe(true);
});

test("extraction is independent of pixel order and safe for empty images", () => {
  const pixels = points([[23, 53, 199], [237, 55, 27], [80, 154, 39], [231, 210, 41]]);
  expect(sampleSpectrumColors(pixels)).toEqual(sampleSpectrumColors([...pixels].reverse()));
  expect(sampleSpectrumColors([])).toEqual([]);
  expect(sampleSpectrumColors([[NaN, 0, 0], [Infinity, 0, 0]])).toEqual([]);
});
