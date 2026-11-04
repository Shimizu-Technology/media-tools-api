import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { AlertCircle, Archive, AudioLines, Check, FileText, FolderPlus, Link2, Mic, Plus, Search, SlidersHorizontal, Star, Trash2, X } from 'lucide-react';
import {
  deleteAudioTranscription,
  deletePDFExtraction,
  deleteTranscript,
  getErrorMessage,
  getLibraryStats,
  listLibraryItems,
  retryAudioTranscription,
  updateLibraryPreferences,
  type LibraryItem,
} from '../lib/api';
import { normalizeItemType } from '../lib/library';
import { DEFAULT_LIBRARY_QUERY, hasLibraryFilters, parseLibraryQuery, serializeLibraryQuery, updateLibraryQuery, type LibraryQuery } from '../lib/libraryQuery';
import { notifyLibraryActivityChanged } from '../lib/libraryActivityEvents';
import { useLibraryActivity } from '../contexts/useLibraryActivity';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { useAuthContext } from '../contexts/useAuthContext';
import { AddToCollectionModal } from '../components/AddToCollectionModal';
import { ItemRow, LoadingRows } from '../components/library/ItemRow';
import { ProcessingLink } from '../components/ProcessingLink';
import { Menu, type MenuItem } from '../components/ui/Menu';
import { Button, ButtonLink } from '../components/ui/Button';
import { Input, Notice } from '../components/ui/Field';
import { APP_ROUTES } from '../lib/appRoutes';

const PER_PAGE = 30;

type Page = { rows: LibraryItem[]; total: number; totalPages: number };

// The last few pages, so Back renders the list at once and scroll restoration
// has something to land on. Each visit still refreshes in the background.
const pageCache = new Map<string, Page>();

async function loadPage(query: LibraryQuery): Promise<Page> {
  const result = await listLibraryItems({
    page: query.page,
    per_page: PER_PAGE,
    search: query.q.trim() || undefined,
    type: query.type || undefined,
    status: query.status || undefined,
    favorite: query.view === 'favorites' ? 'true' : undefined,
    archive: query.view === 'archive' ? 'only' : undefined,
    sort_dir: query.sort,
  });
  return { rows: result.data, total: result.total_items, totalPages: result.total_pages };
}

/** The same three ways in as Home's shortcuts. */
function addItems(go: (path: string) => void): MenuItem[] {
  return [
    { label: 'Import audio', icon: <AudioLines />, onSelect: () => go(`${APP_ROUTES.add}?source=file`) },
    { label: 'Add a link', icon: <Link2 />, onSelect: () => go(`${APP_ROUTES.add}?source=link`) },
    { label: 'Upload a PDF', icon: <FileText />, onSelect: () => go(`${APP_ROUTES.add}?source=pdf`) },
  ];
}

export function LibraryPage() {
  const navigate = useNavigate();
  const { user } = useAuthContext();
  const [params, setParams] = useSearchParams();
  const query = useMemo(() => parseLibraryQuery(params), [params]);
  const queryKey = serializeLibraryQuery(query).toString();
  // One browser can see two accounts: a cached page must not outlive its owner.
  const cacheKey = `${user?.id ?? ''}?${queryKey}`;
  const [page, setPage] = useState<Page | null>(() => pageCache.get(cacheKey) ?? null);
  const [loadedKey, setLoadedKey] = useState(() => (pageCache.has(cacheKey) ? cacheKey : ''));
  const [error, setError] = useState('');
  const [failedCount, setFailedCount] = useState(0);
  const [searchInput, setSearchInput] = useState(query.q);
  const [refreshToken, setRefreshToken] = useState(0);
  const [collectionFor, setCollectionFor] = useState<LibraryItem | null>(null);
  const { activeItems } = useLibraryActivity();
  const { requestConsent } = useAIProcessingConsent();

  const setQuery = useCallback((changes: Partial<LibraryQuery>, replace = false) => {
    setParams(serializeLibraryQuery(updateLibraryQuery(query, changes)), { replace });
  }, [query, setParams]);

  // Search types into the URL (replacing, so Back skips the keystrokes).
  useEffect(() => {
    if (searchInput === query.q) return;
    const timer = window.setTimeout(() => setQuery({ q: searchInput }, true), 300);
    return () => window.clearTimeout(timer);
  }, [query.q, searchInput, setQuery]);

  // Back and forward change the URL under the field.
  const previousQ = useRef(query.q);
  useEffect(() => {
    if (previousQ.current !== query.q) {
      previousQ.current = query.q;
      queueMicrotask(() => setSearchInput(query.q));
    }
  }, [query.q]);

  // Refresh when something finishes or starts processing.
  const activeSignature = activeItems.map((item) => `${item.item_type}:${item.id}:${item.status}`).sort().join('|');

  useEffect(() => {
    let current = true;
    loadPage(query)
      .then((result) => {
        if (!current) return;
        if (result.totalPages > 0 && query.page > result.totalPages) {
          setQuery({ page: result.totalPages }, true);
          return;
        }
        pageCache.set(cacheKey, result);
        if (pageCache.size > 12) pageCache.delete(pageCache.keys().next().value as string);
        setPage(result);
        setLoadedKey(cacheKey);
        setError('');
      })
      .catch((err: unknown) => {
        if (!current) return;
        setError(getErrorMessage(err));
        setLoadedKey(cacheKey);
      });
    return () => { current = false; };
    // query is derived from cacheKey; refresh tokens re-run the same query.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cacheKey, refreshToken, activeSignature]);

  useEffect(() => {
    let current = true;
    getLibraryStats().then((stats) => { if (current) setFailedCount(stats.failed); }).catch(() => undefined);
    return () => { current = false; };
  }, [refreshToken, activeSignature]);

  const refresh = () => setRefreshToken((value) => value + 1);
  const showing = loadedKey === cacheKey || (page !== null && loadedKey !== '');
  const rows = page?.rows ?? [];
  const filtered = hasLibraryFilters(query);
  const clearAll = () => { setSearchInput(''); setParams(serializeLibraryQuery(DEFAULT_LIBRARY_QUERY)); };

  const retry = async (row: LibraryItem) => {
    if (!(await requestConsent())) return;
    try {
      await retryAudioTranscription(row.id);
      notifyLibraryActivityChanged();
      refresh();
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  const remove = async (row: LibraryItem) => {
    if (!window.confirm(`Delete “${row.title}”? This removes the transcript, summary and conversation.`)) return;
    try {
      if (row.item_type === 'youtube') await deleteTranscript(row.id);
      else if (row.item_type === 'audio') await deleteAudioTranscription(row.id);
      else await deletePDFExtraction(row.id);
      pageCache.clear();
      refresh();
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  const setPreference = async (row: LibraryItem, changes: { favorite?: boolean; archived?: boolean }) => {
    try {
      await updateLibraryPreferences(normalizeItemType(row.item_type), row.id, changes);
      pageCache.clear();
      refresh();
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  const rowMenu = (row: LibraryItem): MenuItem[] => [
    { label: 'Add to collection', icon: <FolderPlus />, onSelect: () => setCollectionFor(row) },
    { label: row.favorite ? 'Unstar' : 'Star', icon: <Star />, onSelect: () => void setPreference(row, { favorite: !row.favorite }) },
    { label: row.archived ? 'Move out of archive' : 'Archive', icon: <Archive />, onSelect: () => void setPreference(row, { archived: !row.archived }) },
    { kind: 'separator' },
    { label: 'Delete', icon: <Trash2 />, tone: 'danger', onSelect: () => void remove(row) },
  ];

  return (
    <div className="mx-auto max-w-3xl">
      <div className="flex items-center justify-between gap-3">
        <h1 className="text-large-title">Library</h1>
        <div className="-mr-2 flex items-center">
          <ProcessingLink className="md:hidden" />
          <Menu label="Add to your library" trigger={<Plus className="h-6 w-6" />} items={addItems(navigate)} />
        </div>
      </div>

      <div className="mt-2 flex items-center gap-1">
        <form role="search" className="relative min-w-0 flex-1" onSubmit={(event) => { event.preventDefault(); setQuery({ q: searchInput }); }}>
          <Search className="pointer-events-none absolute left-3 top-1/2 h-[18px] w-[18px] -translate-y-1/2 text-text-secondary" aria-hidden="true" />
          <Input type="search" value={searchInput} onChange={(event) => setSearchInput(event.target.value)} placeholder="Search transcripts and summaries" aria-label="Search your library" className={`pl-10 placeholder:text-callout [&::-webkit-search-cancel-button]:hidden ${searchInput ? 'pr-11' : 'pr-2'}`} />
          {searchInput && (
            <button type="button" onClick={() => { setSearchInput(''); setQuery({ q: '' }); }} aria-label="Clear search" className="absolute right-0 top-0 flex h-11 w-11 items-center justify-center rounded-md text-text-secondary">
              <X className="h-4 w-4" />
            </button>
          )}
        </form>
        <FilterMenu query={query} onChange={setQuery} />
      </div>

      <FilterChips query={query} total={page?.total} onChange={setQuery} />

      {(query.q.trim() || query.status || query.sort === 'asc') && (
        <p className="flex flex-wrap items-center gap-x-1 text-callout text-text-secondary">
          <span>{describeFilters(query)}</span>
          <button type="button" onClick={clearAll} className="inline-flex min-h-11 items-center px-1 font-semibold text-accent-text">Clear</button>
        </p>
      )}

      {!filtered && failedCount > 0 && (
        <button type="button" onClick={() => setQuery({ status: 'failed' })} className="flex min-h-11 items-center gap-2 text-callout">
          <AlertCircle className="h-4 w-4 text-warning" aria-hidden="true" />
          <span>{failedCount === 1 ? '1 item needs attention' : `${failedCount.toLocaleString()} items need attention`}</span>
          <span className="font-semibold text-accent-text">Show</span>
        </button>
      )}

      {error && <div className="mt-3"><Notice tone="error" action={<Button variant="plain" onClick={refresh}>Try again</Button>}>{error}</Notice></div>}

      {!showing && !error ? (
        <LoadingRows label="Loading your library" />
      ) : rows.length === 0 && !error ? (
        <EmptyState filtered={filtered} onClear={clearAll} />
      ) : (
        <div>
          <ul>
            {rows.map((row) => <ItemRow key={`${row.item_type}-${row.id}`} item={row} menu={rowMenu(row)} onRetry={row.item_type === 'audio' ? () => void retry(row) : undefined} />)}
          </ul>
          {page && page.totalPages > 1 && (
            <nav className="mt-4 flex items-center justify-between" aria-label="Pages">
              <Button variant="plain" disabled={query.page <= 1} onClick={() => setQuery({ page: query.page - 1 })}>{query.sort === 'desc' ? 'Newer' : 'Earlier'}</Button>
              <span className="font-mono text-meta text-text-secondary">Page {query.page.toLocaleString()} of {page.totalPages.toLocaleString()}</span>
              <Button variant="plain" disabled={query.page >= page.totalPages} onClick={() => setQuery({ page: query.page + 1 })}>{query.sort === 'desc' ? 'Older' : 'Later'}</Button>
            </nav>
          )}
        </div>
      )}

      {collectionFor && (
        <AddToCollectionModal open onClose={() => setCollectionFor(null)} itemType={normalizeItemType(collectionFor.item_type)} itemId={collectionFor.id} itemTitle={collectionFor.title} onChanged={() => { pageCache.clear(); refresh(); }} />
      )}
    </div>
  );
}

function describeFilters(query: LibraryQuery): string {
  const parts: string[] = [];
  if (query.q.trim()) parts.push(`Matching “${query.q.trim()}”`);
  if (query.status === 'failed') parts.push('Needs attention');
  if (query.status === 'active') parts.push('Processing');
  if (query.status === 'completed') parts.push('Finished');
  if (query.sort === 'asc') parts.push('Oldest first');
  return parts.join(' · ');
}

function FilterChips({ query, total, onChange }: { query: LibraryQuery; total?: number; onChange: (changes: Partial<LibraryQuery>) => void }) {
  const all = !query.type && !query.view;
  const countable = all && !query.q.trim() && !query.status;
  const chips: { label: string; on: boolean; changes: Partial<LibraryQuery> }[] = [
    { label: countable && total !== undefined ? `All ${total.toLocaleString()}` : 'All', on: all, changes: { type: '', view: '' } },
    { label: 'Recordings', on: query.type === 'audio', changes: { type: query.type === 'audio' ? '' : 'audio' } },
    { label: 'Links', on: query.type === 'youtube', changes: { type: query.type === 'youtube' ? '' : 'youtube' } },
    { label: 'PDFs', on: query.type === 'pdf', changes: { type: query.type === 'pdf' ? '' : 'pdf' } },
    { label: 'Starred', on: query.view === 'favorites', changes: { view: query.view === 'favorites' ? '' : 'favorites' } },
    { label: 'Archived', on: query.view === 'archive', changes: { view: query.view === 'archive' ? '' : 'archive' } },
  ];
  return (
    <div className="no-scrollbar -mx-4 mt-1 flex gap-1.5 overflow-x-auto px-4 md:mx-0 md:px-0" role="group" aria-label="Show">
      {chips.map((chip) => (
        <button key={chip.label} type="button" aria-pressed={chip.on} onClick={() => onChange(chip.changes)} className="pressable flex min-h-11 shrink-0 items-center">
          <span className={`inline-flex h-8 items-center rounded-full px-3 text-meta font-semibold transition-colors ${chip.on ? 'bg-accent-fill text-on-accent' : 'bg-surface-2 text-text-secondary'}`}>{chip.label}</span>
        </button>
      ))}
    </div>
  );
}

/** Chips cover the everyday filters; status and order stay one menu away. */
function FilterMenu({ query, onChange }: { query: LibraryQuery; onChange: (changes: Partial<LibraryQuery>) => void }) {
  const mark = (on: boolean) => (on ? <Check /> : undefined);
  const active = Boolean(query.status) || query.sort === 'asc';
  return (
    <Menu
      label="Filter and sort"
      triggerClassName="pressable relative inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-accent-text hover:bg-fill"
      trigger={<><SlidersHorizontal className="h-5 w-5" aria-hidden="true" />{active && <span className="absolute right-2 top-2 h-2 w-2 rounded-full bg-accent-fill" aria-hidden="true" />}</>}
      items={[
        { label: 'Needs attention', icon: mark(query.status === 'failed'), onSelect: () => onChange({ status: query.status === 'failed' ? '' : 'failed' }) },
        { label: 'Processing', icon: mark(query.status === 'active'), onSelect: () => onChange({ status: query.status === 'active' ? '' : 'active' }) },
        { kind: 'separator' },
        { label: query.sort === 'asc' ? 'Newest first' : 'Oldest first', onSelect: () => onChange({ sort: query.sort === 'asc' ? 'desc' : 'asc' }) },
      ]}
    />
  );
}

function EmptyState({ filtered, onClear }: { filtered: boolean; onClear: () => void }) {
  if (filtered) {
    return (
      <div className="py-12">
        <p className="text-heading">Nothing matches</p>
        <p className="mt-2 text-callout text-text-secondary">Try other words, or clear the filters.</p>
        <Button className="mt-4" onClick={onClear}>Show everything</Button>
      </div>
    );
  }
  return (
    <div className="py-12">
      <p className="text-heading">Your library is empty</p>
      <p className="mt-2 max-w-sm text-callout text-text-secondary">Record a thought, paste a video link, or add a PDF. The transcript and summary land here.</p>
      <div className="mt-5 flex flex-wrap gap-2">
        <ButtonLink to={`${APP_ROUTES.add}?record=1`} variant="primary" icon={<Mic className="h-4 w-4" />}>Record</ButtonLink>
        <ButtonLink to={APP_ROUTES.add}>Add a link or file</ButtonLink>
      </div>
    </div>
  );
}

