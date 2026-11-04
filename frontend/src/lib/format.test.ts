import { describe, expect, it } from 'vitest';
import { formatClock, formatDuration, pluralize } from './format';

describe('formatting', () => {
  it('reads durations the way the list shows them', () => {
    expect(formatDuration(0)).toBe('');
    expect(formatDuration(31)).toBe('0:31');
    expect(formatDuration(108)).toBe('1:48');
    expect(formatDuration(720)).toBe('12 min');
    expect(formatDuration(2530)).toBe('42 min');
    expect(formatDuration(3600)).toBe('1 hr');
    expect(formatDuration(4320)).toBe('1 hr 12 min');
  });

  it('formats a running clock', () => {
    expect(formatClock(42, true)).toBe('00:42');
    expect(formatClock(724)).toBe('12:04');
    expect(formatClock(3729)).toBe('1:02:09');
  });

  it('pluralizes counts', () => {
    expect(pluralize(1, 'item')).toBe('1 item');
    expect(pluralize(1200, 'item')).toBe('1,200 items');
  });
});
