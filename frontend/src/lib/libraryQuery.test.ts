import { describe, expect, it } from 'vitest';
import { displayTitle, itemAttention, itemRowView } from './library';
import type { LibraryItem } from './api';
import { DEFAULT_LIBRARY_QUERY, dayLabel, hasLibraryFilters, parseLibraryQuery, serializeLibraryQuery, updateLibraryQuery } from './libraryQuery';

describe('library URL state', () => {
  it('round-trips every filter through the URL', () => {
    const query = { q: 'launch date', type: 'audio', status: 'failed', view: 'archive', sort: 'asc', page: 3 } as const;
    const params = serializeLibraryQuery(query);
    expect(params.toString()).toBe('q=launch+date&type=audio&status=failed&view=archive&sort=asc&page=3');
    expect(parseLibraryQuery(params)).toEqual(query);
  });

  it('keeps defaults out of the URL', () => {
    expect(serializeLibraryQuery(DEFAULT_LIBRARY_QUERY).toString()).toBe('');
    expect(hasLibraryFilters(DEFAULT_LIBRARY_QUERY)).toBe(false);
  });

  it('ignores values the API would reject', () => {
    expect(parseLibraryQuery(new URLSearchParams('type=video&status=everything&view=starred&page=-2&sort=sideways'))).toEqual(DEFAULT_LIBRARY_QUERY);
  });

  it('reads the names older links used', () => {
    expect(parseLibraryQuery(new URLSearchParams('status=processing')).status).toBe('active');
    expect(parseLibraryQuery(new URLSearchParams('status=pending')).status).toBe('active');
    expect(parseLibraryQuery(new URLSearchParams('search=lease')).q).toBe('lease');
  });

  it('returns to page one when a filter changes, but not when the page does', () => {
    const onPageThree = { ...DEFAULT_LIBRARY_QUERY, page: 3 };
    expect(updateLibraryQuery(onPageThree, { type: 'pdf' }).page).toBe(1);
    expect(updateLibraryQuery(onPageThree, { page: 4 }).page).toBe(4);
  });
});

describe('day labels', () => {
  const now = new Date(2026, 10, 5, 9, 30);
  it('labels today, yesterday, this week and older dates', () => {
    expect(dayLabel(new Date(2026, 10, 5, 1, 0), now)).toBe('Today');
    expect(dayLabel(new Date(2026, 10, 4, 22, 0), now)).toBe('Yesterday');
    expect(dayLabel(new Date(2026, 10, 2, 12, 0), now)).not.toContain('Nov');
    expect(dayLabel(new Date(2026, 9, 1, 12, 0), now)).not.toContain('2026');
    expect(dayLabel(new Date(2025, 9, 1, 12, 0), now)).toContain('2025');
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

describe('row fields from a server that may not send them yet', () => {
  const now = new Date(2026, 10, 5, 9, 30);
  const base: LibraryItem = {
    id: 'a', item_type: 'audio', title: 'Call', subtitle: '', status: 'completed', word_count: 10, duration: 516, page_count: 0,
    summary_status: 'completed', favorite: false, archived: false, tags: [], created_at: new Date(2026, 10, 4, 19, 0).toISOString(),
  };

  it('collapses every optional line when the fields are absent', () => {
    expect(itemRowView(base, now)).toMatchObject({ excerpt: null, waveform: null, collection: null, length: '8:36', source: '', day: 'Yesterday' });
  });

  it('treats blank and empty values as absent', () => {
    expect(itemRowView({ ...base, excerpt: '   ', waveform: [], collections: [] }, now)).toMatchObject({ excerpt: null, waveform: null, collection: null });
  });

  it('shows what the server sent, with the oldest collection first', () => {
    const peaks = Array.from({ length: 32 }, (_, index) => index);
    const view = itemRowView({ ...base, excerpt: ' Launch moves. ', waveform: peaks, collections: [{ id: '1', name: 'Baby', color: 'teal' }, { id: '2', name: 'Work', color: 'rose' }] }, now);
    expect(view.excerpt).toBe('Launch moves.');
    expect(view.waveform).toEqual(peaks);
    expect(view.collection).toEqual({ id: '1', name: 'Baby', color: 'teal' });
  });

  it('ignores a waveform on anything that is not audio, and a malformed one', () => {
    expect(itemRowView({ ...base, item_type: 'pdf', waveform: [1, 2, 3] }, now).waveform).toBeNull();
    expect(itemRowView({ ...base, waveform: [1, Number.NaN] }, now).waveform).toBeNull();
  });

  it('names the source and length of links and PDFs', () => {
    expect(itemRowView({ ...base, item_type: 'pdf', duration: 0, page_count: 18 }, now)).toMatchObject({ length: '18p', source: 'PDF' });
    expect(itemRowView({ ...base, item_type: 'youtube', subtitle: 'Law School', duration: 842 }, now)).toMatchObject({ length: '14:02', source: 'Law School' });
    expect(itemRowView({ ...base, item_type: 'youtube', subtitle: 'Unknown channel' }, now).source).toBe('Video');
  });
});
