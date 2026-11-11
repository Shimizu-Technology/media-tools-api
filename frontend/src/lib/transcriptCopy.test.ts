import { describe, expect, it } from 'vitest';
import type { MediaSegment } from './api';
import { transcriptCopyText } from './transcriptCopy';

const segment = (ordinal: number, startMs: number | undefined, text: string): MediaSegment => ({
  id: `s${ordinal}`, item_type: 'audio', item_id: 'a1', ordinal, start_ms: startMs, text, created_at: '',
});

const segments = [segment(1, 0, 'Hello there.'), segment(2, 65_000, 'Second line.'), segment(3, undefined, 'Untimed.')];
const base = { readable: 'Hello there.\n\nSecond line.', original: 'hello there second line', segments };

describe('transcriptCopyText', () => {
  it('copies the plain words when timed lines are only the default view', () => {
    expect(transcriptCopyText({ ...base, mode: 'timestamps', chosen: false })).toBe(base.readable);
  });

  it('keeps the stamps when someone picked the timed view', () => {
    expect(transcriptCopyText({ ...base, mode: 'timestamps', chosen: true })).toBe('[0:00] Hello there.\n[1:05] Second line.');
  });

  it('copies the untouched transcript in the original view', () => {
    expect(transcriptCopyText({ ...base, mode: 'original', chosen: true })).toBe(base.original);
  });

  it('falls back to the readable text when no line has a time', () => {
    expect(transcriptCopyText({ ...base, segments: [segment(1, undefined, 'x')], mode: 'timestamps', chosen: true })).toBe(base.readable);
  });
});
