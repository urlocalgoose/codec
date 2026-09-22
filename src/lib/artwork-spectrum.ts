// Pick representatives that occur in the tiny source image. Unlike cluster
// averages or synthesized hue ramps, these swatches cannot invent a new hue.
// Runs once per cached artwork, never in the visualization's drawing loop.
type Pixel = readonly [number, number, number];
type Bucket = { pixels: Pixel[]; sum: number[] };

const order = (a: Pixel, b: Pixel): number => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
const distance = (a: readonly number[], b: readonly number[]): number =>
  (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2;

export function sampleSpectrumColors(points: readonly (readonly number[])[]): string[] {
  const buckets = new Map<number, Bucket>();
  for (const point of points) {
    if (point.length < 3 || !point.slice(0, 3).every(Number.isFinite)) continue;
    const pixel = point.slice(0, 3).map(value => Math.round(Math.max(0, Math.min(1, value)) * 255)) as unknown as Pixel;
    const key = (pixel[0] >> 5) * 64 + (pixel[1] >> 5) * 8 + (pixel[2] >> 5);
    let bucket = buckets.get(key);
    if (!bucket) { bucket = { pixels: [], sum: [0, 0, 0] }; buckets.set(key, bucket); }
    bucket.pixels.push(pixel);
    pixel.forEach((channel, index) => { bucket.sum[index] += channel; });
  }
  if (!buckets.size) return [];

  const candidates = [...buckets.values()].map(bucket => {
    const mean = bucket.sum.map(value => value / bucket.pixels.length);
    const color = bucket.pixels.reduce((best, pixel) => {
      const delta = distance(pixel, mean) - distance(best, mean);
      return delta < 0 || (delta === 0 && order(pixel, best) < 0) ? pixel : best;
    });
    return { color, count: bucket.pixels.length };
  }).sort((a, b) => b.count - a.count || order(a.color, b.color));
  // Broad bins support textured highlights without requiring a flat, repeated
  // pixel color. Ignore isolated noise, but retain small real cover accents.
  const threshold = Math.max(2, Math.ceil(points.length * .002));
  const supported = candidates.filter(candidate => candidate.count >= threshold);
  const pool = (supported.length ? supported : candidates).slice(0, 128);
  const selected: Pixel[] = [pool[0].color];
  while (selected.length < 4) {
    let best: Pixel | null = null, bestScore = -1;
    for (const candidate of pool) {
      const nearest = Math.min(...selected.map(color => distance(color, candidate.color))) / (255 * 255);
      // Similar shades need not pretend to be four separate colors. A cover
      // with one or two colors keeps one or two colors in its visualizer.
      if (nearest < .0025) continue;
      // After support filtering, prioritize separation within the actual art.
      // Weighting by area again would bury the cover's small vivid highlights
      // under its large dark background.
      const score = nearest;
      if (score > bestScore) { best = candidate.color; bestScore = score; }
    }
    if (!best) break;
    selected.push(best);
  }
  return selected.map(color => `rgb(${color.join(" ")})`);
}
