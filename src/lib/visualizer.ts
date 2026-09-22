/** Shared spectrograph sampling. The sampler runs from the moment the audio
 * graph exists — whatever view is open — into a ring buffer, so opening the
 * Visualizer paints the recent past instead of starting blank. */

import { spectrumColorTable, spectrumPalette, type SpectrumColors } from "./visualizer-palette";

export const SPECTRO_BANDS = 112;

function snapshotColors(colors: SpectrumColors): SpectrumColors {
  if (Object.isFrozen(colors) && Object.isFrozen(colors.ink) && Object.isFrozen(colors.alpha)) return colors;
  return Object.freeze({ background: colors.background,
    ink: Object.freeze([...colors.ink]), alpha: Object.freeze([...colors.alpha]) });
}

export class SpectroSampler {
  readonly bands = SPECTRO_BANDS;

  private readonly capacity: number;
  private readonly buffer: Uint8Array;
  private readonly bins: Uint8Array;
  private readonly analyser: AnalyserNode;
  // One shared immutable table reference per column. The ring bounds their
  // lifetime; changing tracks never rewrites the colors of recorded audio.
  private readonly appearances: SpectrumColors[];
  private colors: SpectrumColors;
  private readonly colorListeners = new Set<() => void>();
  private total = 0;
  private raf = 0;
  private running = false;
  private readonly tick = () => {
    if (!this.running) return;
    this.sample();
    this.raf = requestAnimationFrame(this.tick);
  };

  constructor(analyser: AnalyserNode, capacity = 1600, colors?: SpectrumColors) {
    this.analyser = analyser;
    this.capacity = capacity;
    this.buffer = new Uint8Array(capacity * SPECTRO_BANDS);
    this.bins = new Uint8Array(analyser.frequencyBinCount);
    this.appearances = new Array(capacity);
    this.colors = snapshotColors(colors ?? spectrumColorTable(spectrumPalette({ bg: "#101312", accent: "#a7b0aa", text: "#eef2ed" }, null)));

    this.start();
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.tick();
  }

  stop(): void {
    this.running = false;
    cancelAnimationFrame(this.raf);
    this.raf = 0;
  }

  /** Total columns ever sampled; the retained window ends here. */
  get count(): number {
    return this.total;
  }

  /** First column index still held by the ring buffer. */
  get oldestIndex(): number {
    return Math.max(0, this.total - this.capacity);
  }

  get currentColors(): SpectrumColors { return this.colors; }

  /** Applies only to future columns, including while the visualizer is closed. */
  setColors(colors: SpectrumColors): void {
    if (colors === this.colors || (colors.background === this.colors.background
      && colors.ink.every((value, index) => value === this.colors.ink[index])
      && colors.alpha.every((value, index) => value === this.colors.alpha[index]))) return;
    this.colors = snapshotColors(colors);
    for (const listener of this.colorListeners) listener();
  }

  subscribeColors(listener: () => void): () => void {
    this.colorListeners.add(listener);
    return () => { this.colorListeners.delete(listener); };
  }

  colorsAt(index: number): SpectrumColors {
    if (index < this.oldestIndex || index >= this.count) throw new RangeError("Spectrum column is outside retained history");
    return this.appearances[index % this.capacity];
  }

  /** Copies the band magnitudes of absolute column `index` into `out`
   * (length SPECTRO_BANDS). Callers must stay within the retained window. */
  column(index: number, out: Uint8Array): void {
    const offset = (index % this.capacity) * SPECTRO_BANDS;
    out.set(this.buffer.subarray(offset, offset + SPECTRO_BANDS));
  }

  private sample(): void {
    this.analyser.getByteFrequencyData(this.bins);
    const maxBin = this.bins.length - 1;
    const offset = (this.total % this.capacity) * SPECTRO_BANDS;

    for (let band = 0; band < SPECTRO_BANDS; band += 1) {
      // Exponential frequency mapping: fine resolution for the lows, the
      // highs compressed — reads musically, like a real spectrograph.
      const from = Math.floor(Math.pow(maxBin, band / SPECTRO_BANDS));
      const to = Math.max(from + 1, Math.floor(Math.pow(maxBin, (band + 1) / SPECTRO_BANDS)));
      let sum = 0;
      for (let bin = from; bin < to; bin += 1) {
        sum += this.bins[bin];
      }
      this.buffer[offset + band] = Math.round(sum / (to - from));
    }

    this.appearances[this.total % this.capacity] = this.colors;
    this.total += 1;
  }
}
