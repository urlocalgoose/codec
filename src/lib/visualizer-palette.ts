import type { ArtworkSample } from "./artwork-atmosphere";

type RGB = readonly [number, number, number];
export type SpectrumPalette = { bg: RGB; cool: RGB; mid: RGB; warm: RGB; hot: RGB; artwork: boolean };
export type SpectrumTheme = { bg: string; accent: string; text: string };
export type SpectrumColors = Readonly<{ background: string; ink: readonly string[]; alpha: readonly number[] }>;

export function readSpectrumTheme(element: Element): SpectrumTheme {
  const style = getComputedStyle(element);
  return {
    bg: style.getPropertyValue("--color-bg").trim() || "#101312",
    accent: style.getPropertyValue("--color-accent").trim() || "#a7b0aa",
    text: style.getPropertyValue("--color-text").trim() || "#eef2ed"
  };
}

function rgb(value: string): RGB {
  if (/^#[\da-f]{6}$/i.test(value)) return [1, 3, 5].map(i => parseInt(value.slice(i, i + 2), 16) / 255) as unknown as RGB;
  if (/^#[\da-f]{3}$/i.test(value)) return [1, 2, 3].map(i => parseInt(value[i] + value[i], 16) / 255) as unknown as RGB;
  return (value.match(/[\d.]+/g) ?? ["0", "0", "0"]).slice(0, 3).map(Number).map(v => v / 255) as unknown as RGB;
}

export const spectrumBrightness = (color: RGB): number => color[0] * .2126 + color[1] * .7152 + color[2] * .0722;
const mix = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const css = (color: RGB): string => `rgb(${color.map(v => Math.round(Math.max(0, Math.min(1, v)) * 255)).join(" ")})`;

type SpectrumSample = Pick<ArtworkSample, "cool" | "warm" | "deep"> & Partial<Pick<ArtworkSample, "spectrum">>;

export function spectrumPalette(theme: SpectrumTheme, sample: SpectrumSample | null): SpectrumPalette {
  const themeBG = rgb(theme.bg), light = spectrumBrightness(themeBG) > .5;
  const bg = sample ? mix(themeBG, rgb(sample.deep), .16) : themeBG;
  // The stored representatives are actual source pixels. No hue snapping,
  // complementary colors, saturation boost, or theme accent enters artwork ink.
  // Legacy samples still use only their existing artwork colors.
  const source = sample
    ? sample.spectrum?.length ? sample.spectrum : [sample.deep, sample.cool, sample.warm]
    : [theme.accent, theme.text];
  const unique = new Map<string, RGB>();
  for (const value of source) { const color = rgb(value); unique.set(color.join(","), color); }
  const sorted = [...unique.values()].sort((a, b) => spectrumBrightness(a) - spectrumBrightness(b)
    || a[0] - b[0] || a[1] - b[1] || a[2] - b[2]);
  if (light) sorted.reverse();
  // Put stronger light/dark contrast at higher energy without recoloring the
  // cover. Fewer than four distinct source colors simply repeat across bands.
  const bands = [0, 1, 2, 3].map(index => sorted[Math.round(index * (sorted.length - 1) / 3)]);
  return { bg, cool: bands[0], mid: bands[1], warm: bands[2], hot: bands[3], artwork: sample !== null };
}

// Hard color zones preserve adjacent cool/hot features instead of blending
// them through a muddy midpoint. Opacity still expresses fine amplitude detail.
// Both tables are prepared on palette changes, never per drawing cell.
export function spectrumColorTable(palette: SpectrumPalette): SpectrumColors {
  const bands = [palette.cool, palette.mid, palette.warm, palette.hot].map(css);
  return Object.freeze({
    background: css(palette.bg),
    ink: Object.freeze(Array.from({ length: 256 }, (_, byte) => bands[byte < 64 ? 0 : byte < 128 ? 1 : byte < 204 ? 2 : 3])),
    alpha: spectrumOpacity
  });
}

const spectrumOpacity = Object.freeze(Array.from({ length: 256 }, (_, byte) => Math.pow(byte / 255, .55)));
