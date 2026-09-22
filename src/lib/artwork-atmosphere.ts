import { artworkCache } from "./artwork-cache";
import { sampleSpectrumColors } from "./artwork-spectrum";
// Shared by Now Playing and the visualizer. A song is sampled once, not once
// per surface or animation frame. Authentication URL rotation keeps its cache key.
export type ArtworkSample = { warm: string; cool: string; deep: string; blurred: string; spectrum: string[] };
const samples = new Map<string, Promise<ArtworkSample | null>>();

export function artworkIdentity(url: string): string {
  if (!url) return "";
  try {
    const parsed = new URL(url, typeof document === "undefined" ? undefined : document.baseURI);
    parsed.searchParams.delete("access_token");
    return parsed.href;
  } catch { return url; }
}

export function sampleArtwork(url: string, identity: string): Promise<ArtworkSample | null> {
  identity = `${artworkCache.generation}:${identity}`;
  const cached = samples.get(identity);
  if (cached) { samples.delete(identity); samples.set(identity, cached); return cached; }
  const request = new Promise<ArtworkSample | null>((resolve) => {
    const image = new Image();
    const lease = artworkCache.acquire(url);
    image.crossOrigin = "anonymous";
    image.onload = () => {
      lease.release();
      // Only this tiny, cached image is processed; the visible cover stays sharp.
      const side = 48;
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = side;
      const context = canvas.getContext("2d", { willReadFrequently: true });
      if (!context) { resolve(null); return; }
      try {
        context.drawImage(image, 0, 0, side, side);
        const pixels = context.getImageData(0, 0, side, side);
        const points: number[][] = [];
        for (let i = 0; i < pixels.data.length; i += 4) {
          if (pixels.data[i + 3]) points.push([pixels.data[i] / 255, pixels.data[i + 1] / 255, pixels.data[i + 2] / 255]);
        }
        if (!points.length) { resolve(null); return; }
        let centers = [0, 200, 600, 1100, 1700, 2200].map((index) => points[Math.min(points.length - 1, Math.floor(index * points.length / (side * side)))]);
        for (let pass = 0; pass < 10; pass += 1) {
          const sums = centers.map(() => [0, 0, 0]);
          const counts = centers.map(() => 0);
          for (const point of points) {
            let nearest = 0;
            let minimum = Infinity;
            centers.forEach((center, index) => {
              const distance = (point[0] - center[0]) ** 2 + (point[1] - center[1]) ** 2 + (point[2] - center[2]) ** 2;
              if (distance < minimum) { nearest = index; minimum = distance; }
            });
            point.forEach((channel, index) => { sums[nearest][index] += channel; });
            counts[nearest] += 1;
          }
          centers = centers.map((center, index) => counts[index] ? sums[index].map((sum) => sum / counts[index]) : center);
        }
        const warm = centers.reduce((a, b) => a[0] - a[2] >= b[0] - b[2] ? a : b);
        const cool = centers.reduce((a, b) => a[2] - a[0] >= b[2] - b[0] ? a : b);
        const deep = centers.reduce((a, b) => a[0] + a[1] + a[2] <= b[0] + b[1] + b[2] ? a : b);

        // A separable Gaussian matches the native clamped 7px blur without
        // relying on Canvas filter support or filtering every display frame.
        const radius = 21;
        const kernel = Array.from({ length: radius * 2 + 1 }, (_, index) => Math.exp(-((index - radius) ** 2) / 98));
        const total = kernel.reduce((sum, weight) => sum + weight, 0);
        const horizontal = new Float32Array(pixels.data.length);
        const blurred = new Uint8ClampedArray(pixels.data.length);
        for (let y = 0; y < side; y += 1) for (let x = 0; x < side; x += 1) {
          for (let channel = 0; channel < 4; channel += 1) {
            let value = 0;
            for (let offset = -radius; offset <= radius; offset += 1) {
              const index = (y * side + Math.max(0, Math.min(side - 1, x + offset))) * 4;
              value += pixels.data[index + channel] * (channel === 3 ? 1 : pixels.data[index + 3] / 255) * kernel[offset + radius];
            }
            horizontal[(y * side + x) * 4 + channel] = value / total;
          }
        }
        for (let y = 0; y < side; y += 1) for (let x = 0; x < side; x += 1) {
          const values = [0, 0, 0, 0];
          for (let offset = -radius; offset <= radius; offset += 1) {
            const index = (Math.max(0, Math.min(side - 1, y + offset)) * side + x) * 4;
            for (let channel = 0; channel < 4; channel += 1) values[channel] += horizontal[index + channel] * kernel[offset + radius] / total;
          }
          for (let channel = 0; channel < 4; channel += 1) blurred[(y * side + x) * 4 + channel] = channel === 3 ? values[3] : values[3] ? values[channel] * 255 / values[3] : 0;
        }
        context.putImageData(new ImageData(blurred, side, side), 0, 0);
        const color = (rgb: number[]) => `rgb(${rgb.map((value) => Math.round(value * 255)).join(" ")})`;
        resolve({ warm: color(warm), cool: color(cool), deep: color(deep), blurred: canvas.toDataURL(), spectrum: sampleSpectrumColors(points) });
      } catch {
        // An artwork host without CORS can still show the sharp cover; keep
        // the ordinary theme when its pixels cannot safely be sampled.
        resolve(null);
      }
    };
    image.onerror = () => { lease.release(); resolve(null); };
    void lease.ready.then(source => { image.src = source; }, (error: unknown) => {
      if (error instanceof Error && error.name === "AbortError") { lease.release(); resolve(null); }
      else image.src = url;
    });
  });
  samples.set(identity, request);
  void request.then((value) => { if (!value && samples.get(identity) === request) samples.delete(identity); });
  if (samples.size > 12) samples.delete(samples.keys().next().value!);
  return request;
}
