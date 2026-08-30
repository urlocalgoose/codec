/** Shared spectrograph sampling. The sampler runs from the moment the audio
 * graph exists — whatever view is open — into a ring buffer, so opening the
 * Visualizer paints the recent past instead of starting blank. */

export const SPECTRO_BANDS = 112;

export class SpectroSampler {
  readonly bands = SPECTRO_BANDS;

  private readonly capacity: number;
  private readonly buffer: Uint8Array;
  private readonly bins: Uint8Array;
  private readonly analyser: AnalyserNode;
  private total = 0;
  private raf = 0;

  constructor(analyser: AnalyserNode, capacity = 1600) {
    this.analyser = analyser;
    this.capacity = capacity;
    this.buffer = new Uint8Array(capacity * SPECTRO_BANDS);
    this.bins = new Uint8Array(analyser.frequencyBinCount);

    const tick = () => {
      this.raf = requestAnimationFrame(tick);
      this.sample();
    };
    tick();
  }

  stop(): void {
    cancelAnimationFrame(this.raf);
  }

  /** Total columns ever sampled; the retained window ends here. */
  get count(): number {
    return this.total;
  }

  /** First column index still held by the ring buffer. */
  get oldestIndex(): number {
    return Math.max(0, this.total - this.capacity);
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

    this.total += 1;
  }
}
