/**
 * The Library's search, filters and page live in the URL, so Back returns to
 * exactly the list that was showing.
 */
export type LibraryType = '' | 'youtube' | 'audio' | 'pdf';
export type LibraryStatus = '' | 'active' | 'failed' | 'completed';
export type LibraryView = '' | 'favorites' | 'archive';

export type LibraryQuery = {
  q: string;
  type: LibraryType;
  status: LibraryStatus;
  view: LibraryView;
  sort: 'desc' | 'asc';
  page: number;
};

export const DEFAULT_LIBRARY_QUERY: LibraryQuery = { q: '', type: '', status: '', view: '', sort: 'desc', page: 1 };

export function parseLibraryQuery(params: URLSearchParams): LibraryQuery {
  const type = params.get('type');
  const status = params.get('status');
  // The names older links used, from before Library and Processing were one page.
  const activeAlias = status === 'processing' || status === 'pending';
  const view = params.get('view');
  const page = Number.parseInt(params.get('page') ?? '1', 10);
  return {
    q: (params.get('q') ?? params.get('search') ?? '').slice(0, 200),
    type: type === 'youtube' || type === 'audio' || type === 'pdf' ? type : '',
    status: activeAlias ? 'active' : status === 'active' || status === 'failed' || status === 'completed' ? status : '',
    view: view === 'favorites' || view === 'archive' ? view : '',
    sort: params.get('sort') === 'asc' ? 'asc' : 'desc',
    page: Number.isFinite(page) && page > 1 ? Math.min(page, 10000) : 1,
  };
}

/** Only non-default values reach the URL, in a stable order. */
export function serializeLibraryQuery(query: LibraryQuery): URLSearchParams {
  const params = new URLSearchParams();
  if (query.q.trim()) params.set('q', query.q.trim());
  if (query.type) params.set('type', query.type);
  if (query.status) params.set('status', query.status);
  if (query.view) params.set('view', query.view);
  if (query.sort === 'asc') params.set('sort', 'asc');
  if (query.page > 1) params.set('page', String(query.page));
  return params;
}

/** Changing anything but the page starts again at page one. */
export function updateLibraryQuery(query: LibraryQuery, changes: Partial<LibraryQuery>): LibraryQuery {
  const next = { ...query, ...changes };
  if (!('page' in changes)) next.page = 1;
  return next;
}

export function hasLibraryFilters(query: LibraryQuery): boolean {
  return Boolean(query.q.trim() || query.type || query.status || query.view || query.sort === 'asc');
}

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/** Today, Yesterday, then the weekday within a week, then the date. */
export function dayLabel(value: Date, now: Date): string {
  const days = Math.round((startOfDay(now) - startOfDay(value)) / 86_400_000);
  if (days === 0) return 'Today';
  if (days === 1) return 'Yesterday';
  if (days > 1 && days < 7) return new Intl.DateTimeFormat(undefined, { weekday: 'long' }).format(value);
  const sameYear = value.getFullYear() === now.getFullYear();
  return new Intl.DateTimeFormat(undefined, sameYear ? { month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: 'numeric' }).format(value);
}
