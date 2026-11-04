import { describe, expect, it } from 'vitest';
import type { LibraryItem } from './api';
import { greeting, isRecentFailure, selectNeedsYou } from './needsYou';
import type { PendingRecording } from './recordingStore';

const NOW = Date.parse('2026-11-05T12:00:00Z');
const DAY = 86_400_000;

function item(overrides: Partial<LibraryItem> = {}): LibraryItem {
  return {
    id: 'a', item_type: 'audio', title: 'Call', subtitle: '', status: 'failed', word_count: 0, duration: 0, page_count: 0,
    summary_status: 'none', favorite: false, archived: false, tags: [], created_at: new Date(NOW - DAY).toISOString(), ...overrides,
  };
}

function recording(id: string, createdAt: number): PendingRecording {
  return { id, blob: new Blob(['x']), mimeType: 'audio/webm', durationSeconds: 60, createdAt };
}

describe('Needs You', () => {
  it('is empty when nothing needs a person, so the section disappears', () => {
    expect(selectNeedsYou([], [], NOW)).toEqual([]);
  });

  it('keeps failures from the last seven days, including the boundary', () => {
    expect(isRecentFailure(item({ created_at: new Date(NOW - 7 * DAY).toISOString() }), NOW)).toBe(true);
    expect(isRecentFailure(item({ created_at: new Date(NOW - 7 * DAY - 1).toISOString() }), NOW)).toBe(false);
  });

  it('leaves older, archived, unreadable and unfailed items in the Library', () => {
    const entries = selectNeedsYou([
      item({ id: 'old', created_at: new Date(NOW - 30 * DAY).toISOString() }),
      item({ id: 'archived', archived: true }),
      item({ id: 'bad-date', created_at: 'not a date' }),
      item({ id: 'done', status: 'completed' }),
    ], [], NOW);
    expect(entries).toEqual([]);
  });

  it('lists recordings in this browser first, then failures, newest first', () => {
    const entries = selectNeedsYou(
      [item({ id: 'older', created_at: new Date(NOW - 3 * DAY).toISOString() }), item({ id: 'newer', created_at: new Date(NOW - DAY).toISOString() })],
      [recording('first', NOW - 5 * DAY), recording('second', NOW - DAY)],
      NOW,
    );
    expect(entries.map((entry) => entry.key)).toEqual(['recording-second', 'recording-first', 'audio-newer', 'audio-older']);
  });

  it('keeps a recording in this browser however old it is', () => {
    expect(selectNeedsYou([], [recording('ancient', NOW - 90 * DAY)], NOW)).toHaveLength(1);
  });
});

describe('greeting', () => {
  it.each([[5, 'Good morning'], [11, 'Good morning'], [12, 'Good afternoon'], [16, 'Good afternoon'], [17, 'Good evening'], [23, 'Good evening'], [0, 'Good evening'], [4, 'Good evening']])('at %i is %s', (hour, text) => {
    expect(greeting(hour)).toBe(text);
  });
});
