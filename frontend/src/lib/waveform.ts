/**
 * Waveforms are real audio data from the server: integers from 0 to 100. This
 * file only prepares them for display. It never invents a value; anything
 * unusable returns null and the caller shows the item's type icon instead.
 */
const MIN_PEAKS = 2;

/** The peaks as numbers from 0 to 100, or null when there is nothing real to draw. */
export function normalizeWaveform(value: unknown): number[] | null {
  if (!Array.isArray(value) || value.length < MIN_PEAKS) return null;
  const peaks: number[] = [];
  for (const entry of value) {
    if (typeof entry !== 'number' || !Number.isFinite(entry)) return null;
    peaks.push(Math.min(100, Math.max(0, entry)));
  }
  return peaks;
}

/**
 * Fit the peaks to `bars` bars. Each bar shows the loudest peak in its stretch
 * of the recording, so a short spike survives. With fewer peaks than bars the
 * peaks are shown as they are: stretching would draw detail that is not there.
 */
export function sampleWaveform(peaks: readonly number[], bars: number): number[] {
  const count = Math.floor(bars);
  if (count <= 0 || peaks.length === 0) return [];
  if (peaks.length <= count) return [...peaks];
  const sampled: number[] = [];
  for (let bar = 0; bar < count; bar += 1) {
    const start = Math.floor((bar * peaks.length) / count);
    const end = Math.max(start + 1, Math.floor(((bar + 1) * peaks.length) / count));
    let loudest = 0;
    for (let index = start; index < end; index += 1) loudest = Math.max(loudest, peaks[index]);
    sampled.push(loudest);
  }
  return sampled;
}

export type TimedSegment = { id: string; start_ms?: number; end_ms?: number };

/**
 * The segment playing at `ms`: the last one that has started, unless it has
 * ended and the recording is in a silence before the next.
 */
export function activeSegmentId(segments: readonly TimedSegment[], ms: number): string | null {
  let low = 0;
  let high = segments.length - 1;
  let found = -1;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    if ((segments[middle].start_ms ?? 0) <= ms) {
      found = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  if (found < 0) return null;
  const segment = segments[found];
  if (typeof segment.end_ms === 'number' && segment.end_ms > (segment.start_ms ?? 0) && ms >= segment.end_ms) return null;
  return segment.id;
}
