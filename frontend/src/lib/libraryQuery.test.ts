import { describe, expect, it } from 'vitest';
import { displayTitle, itemAttention } from './library';
import { DEFAULT_LIBRARY_QUERY, groupByDay, hasLibraryFilters, parseLibraryQuery, serializeLibraryQuery, updateLibraryQuery } from './libraryQuery';

describe('library URL state', () => {
  it('round-trips every filter through the URL', () => {
    const query = { q: 'launch date', type: 'audio', status: 'failed', view: 'archive', collection: 'abc-1', sort: 'asc', page: 3 } as const;
    const params = serializeLibraryQuery(query);
    expect(params.toString()).toBe('q=launch+date&collection=abc-1&type=audio&status=failed&view=archive&sort=asc&page=3');
    expect(parseLibraryQuery(params)).toEqual(query);
  });

  it('keeps defaults out of the URL', () => {
    expect(serializeLibraryQuery(DEFAULT_LIBRARY_QUERY).toString()).toBe('');
    expect(hasLibraryFilters(DEFAULT_LIBRARY_QUERY)).toBe(false);
  });

  it('ignores values the API would reject', () => {
    expect(parseLibraryQuery(new URLSearchParams('type=video&status=processing&view=starred&page=-2&collection=../x&sort=sideways'))).toEqual(DEFAULT_LIBRARY_QUERY);
  });

  it('returns to page one when a filter changes, but not when the page does', () => {
    const onPageThree = { ...DEFAULT_LIBRARY_QUERY, page: 3 };
    expect(updateLibraryQuery(onPageThree, { type: 'pdf' }).page).toBe(1);
    expect(updateLibraryQuery(onPageThree, { page: 4 }).page).toBe(4);
  });
});

describe('grouping by day', () => {
  const now = new Date(2026, 10, 5, 9, 30);
  it('labels today, yesterday, this week and older dates', () => {
    const items = [
      new Date(2026, 10, 5, 8, 0),
      new Date(2026, 10, 5, 1, 0),
      new Date(2026, 10, 4, 22, 0),
      new Date(2026, 10, 2, 12, 0),
      new Date(2026, 9, 1, 12, 0),
      new Date(2025, 9, 1, 12, 0),
    ].map((date) => date.toISOString());
    const groups = groupByDay(items, (value) => value, now);
    expect(groups.map((group) => group.items.length)).toEqual([2, 1, 1, 1, 1]);
    expect(groups[0].label).toBe('Today');
    expect(groups[1].label).toBe('Yesterday');
    expect(groups[4].label).toContain('2025');
  });
});

describe('item attention', () => {
  const base = { item_type: 'audio' as const, status: 'completed', summary_status: 'completed', word_count: 100 };
  it('says nothing about a finished item', () => {
    expect(itemAttention(base)).toBeNull();
  });
  it('names what is still moving', () => {
    expect(itemAttention({ ...base, status: 'processing', summary_status: 'none', word_count: 0 })?.label).toBe('Transcribing');
    expect(itemAttention({ ...base, status: 'processing', summary_status: 'processing' })?.label).toBe('Writing summary');
    expect(itemAttention({ ...base, item_type: 'youtube', status: 'pending', summary_status: '', word_count: 0 })?.label).toBe('Getting transcript');
  });
  it('flags failures', () => {
    expect(itemAttention({ ...base, status: 'failed' })).toEqual({ kind: 'failed', label: 'Transcription failed' });
  });
});

describe('display titles', () => {
  it('drops a media file extension but keeps everything else', () => {
    expect(displayTitle('Planning call.m4a')).toBe('Planning call');
    expect(displayTitle('Recording 2026-11-05 09.12.webm')).toBe('Recording 2026-11-05 09.12');
    expect(displayTitle('Contract v2.pdf')).toBe('Contract v2.pdf');
    expect(displayTitle('.m4a')).toBe('.m4a');
  });
});
