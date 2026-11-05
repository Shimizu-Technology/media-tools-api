import { describe, expect, it } from 'vitest';
import { activeSegmentId, normalizeWaveform, sampleWaveform } from './waveform';

describe('normalizeWaveform', () => {
  it('keeps real peaks and clamps them to 0..100', () => {
    expect(normalizeWaveform([0, 12, 40, 140, -3])).toEqual([0, 12, 40, 100, 0]);
  });

  it('keeps a silent recording: all zeros is real data', () => {
    expect(normalizeWaveform([0, 0, 0])).toEqual([0, 0, 0]);
  });

  it.each([[undefined], [null], [[]], [[50]], ['0,12'], [[1, '2']], [[1, Number.NaN]], [[1, Infinity]], [{ length: 3 }]])('returns null for %j', (value) => {
    expect(normalizeWaveform(value)).toBeNull();
  });
});

describe('sampleWaveform', () => {
  it('returns exactly the requested bars when downsampling', () => {
    const peaks = Array.from({ length: 200 }, (_, index) => index % 101);
    expect(sampleWaveform(peaks, 64)).toHaveLength(64);
    expect(sampleWaveform(peaks, 16)).toHaveLength(16);
    expect(sampleWaveform(Array.from({ length: 32 }, () => 5), 16)).toHaveLength(16);
  });

  it('keeps a short spike by showing the loudest peak in each stretch', () => {
    const peaks = Array.from({ length: 200 }, () => 4);
    peaks[137] = 96;
    const sampled = sampleWaveform(peaks, 32);
    expect(Math.max(...sampled)).toBe(96);
    expect(sampled.filter((value) => value === 96)).toHaveLength(1);
  });

  it('places a peak in proportion to where it is in the recording', () => {
    const peaks = Array.from({ length: 200 }, () => 0);
    peaks[150] = 80;
    expect(sampleWaveform(peaks, 20).indexOf(80)).toBe(15);
  });

  it('never stretches: fewer peaks than bars come back unchanged', () => {
    expect(sampleWaveform([1, 2, 3], 16)).toEqual([1, 2, 3]);
  });

  it('never invents a value', () => {
    const peaks = [3, 7, 11, 19, 23, 29, 31, 37];
    for (const value of sampleWaveform(peaks, 3)) expect(peaks).toContain(value);
  });

  it('handles empty input and impossible sizes', () => {
    expect(sampleWaveform([], 16)).toEqual([]);
    expect(sampleWaveform([1, 2], 0)).toEqual([]);
    expect(sampleWaveform([1, 2], -4)).toEqual([]);
  });
});

describe('activeSegmentId', () => {
  const segments = [
    { id: 'a', start_ms: 0, end_ms: 4000 },
    { id: 'b', start_ms: 4000, end_ms: 9000 },
    { id: 'c', start_ms: 12000, end_ms: 15000 },
  ];

  it.each([[0, 'a'], [3999, 'a'], [4000, 'b'], [8999, 'b'], [12000, 'c'], [14999, 'c']])('at %i ms it is %s', (ms, id) => {
    expect(activeSegmentId(segments, ms)).toBe(id);
  });

  it('highlights nothing in a gap or after the end', () => {
    expect(activeSegmentId(segments, 10000)).toBeNull();
    expect(activeSegmentId(segments, 20000)).toBeNull();
  });

  it('highlights nothing before the first segment or without segments', () => {
    expect(activeSegmentId([{ id: 'late', start_ms: 5000 }], 100)).toBeNull();
    expect(activeSegmentId([], 100)).toBeNull();
  });

  it('keeps a segment with no end time until the next one starts', () => {
    expect(activeSegmentId([{ id: 'open', start_ms: 0 }, { id: 'next', start_ms: 6000 }], 5000)).toBe('open');
  });
});
