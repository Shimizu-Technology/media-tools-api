import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { AlertCircle, Archive, Check, ChevronDown, FolderPlus, Loader2, MessageSquare, Mic, MoreHorizontal, Pencil, Search, SlidersHorizontal, Star, Trash2, X } from 'lucide-react';
import {
  deleteAudioTranscription,
  deleteCollection,
  deletePDFExtraction,
  deleteTranscript,
  getCollection,
  getErrorMessage,
  getLibraryStats,
  listCollections,
  listLibraryItems,
  removeCollectionItem,
  retryAudioTranscription,
  updateCollection,
  updateLibraryPreferences,
  type Collection,
  type LibraryItem,
} from '../lib/api';
import { displayTitle, itemAttention, itemDetailPath, normalizeItemType } from '../lib/library';
import { DEFAULT_LIBRARY_QUERY, groupByDay, hasLibraryFilters, parseLibraryQuery, serializeLibraryQuery, updateLibraryQuery, type LibraryQuery } from '../lib/libraryQuery';
import { formatDuration, formatTimeOfDay, pluralize } from '../lib/format';
import { notifyLibraryActivityChanged } from '../lib/libraryActivityEvents';
import { useLibraryActivity } from '../contexts/useLibraryActivity';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { AddToCollectionModal } from '../components/AddToCollectionModal';
import { ChatPanel } from '../components/ChatPanel';
import { Menu, type MenuItem } from '../components/ui/Menu';
import { Dialog } from '../components/ui/Dialog';
import { Button, ButtonLink } from '../components/ui/Button';
import { Input, Notice } from '../components/ui/Field';
import { APP_ROUTES } from '../lib/appRoutes';

const PER_PAGE = 30;

type Row = LibraryItem & { collectionItemId?: string };
type Page = { rows: Row[]; total: number; totalPages: number; collection?: Collection };

// The last few pages, so Back renders the list at once and scroll restoration
// has something to land on. Each visit still refreshes in the background.
const pageCache = new Map<string, Page>();

async function loadPage(query: LibraryQuery): Promise<Page> {
  if (query.collection) {
    const collection = await getCollection(query.collection);
    const needle = query.q.trim().toLocaleLowerCase();
    const rows: Row[] = collection.items
      .map((entry) => ({
        id: entry.item_id,
        collectionItemId: entry.id,
        item_type: entry.item_type === 'transcript' ? 'youtube' as const : entry.item_type,
        title: entry.item_title || 'Untitled',
        subtitle: '',
        status: entry.item_status || 'completed',
        word_count: 0,
        duration: 0,
        page_count: 0,
        summary_status: '',
        favorite: false,
        archived: false,
        tags: [],
        created_at: entry.added_at,
      }))
      .filter((row) => !needle || row.title.toLocaleLowerCase().includes(needle))
      .filter((row) => !query.type || row.item_type === query.type);
    return { rows, total: rows.length, totalPages: 1, collection };
  }
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

export function LibraryPage() {
  const [params, setParams] = useSearchParams();
  const query = useMemo(() => parseLibraryQuery(params), [params]);
  const cacheKey = serializeLibraryQuery(query).toString();
  const [page, setPage] = useState<Page | null>(() => pageCache.get(cacheKey) ?? null);
  const [loadedKey, setLoadedKey] = useState(() => (pageCache.has(cacheKey) ? cacheKey : ''));
  const [error, setError] = useState('');
  const [failedCount, setFailedCount] = useState(0);
  const [collections, setCollections] = useState<Collection[]>([]);
  const [searchInput, setSearchInput] = useState(query.q);
  const [refreshToken, setRefreshToken] = useState(0);
  const [collectionFor, setCollectionFor] = useState<Row | null>(null);
  const [renaming, setRenaming] = useState(false);
  const [askingCollection, setAskingCollection] = useState(false);
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
    listCollections().then((list) => { if (current) setCollections(list); }).catch(() => undefined);
    return () => { current = false; };
  }, [refreshToken, activeSignature]);

  const refresh = () => setRefreshToken((value) => value + 1);
  const showing = loadedKey === cacheKey || (page !== null && loadedKey !== '');
  const rows = useMemo(() => page?.rows ?? [], [page]);
  const groups = useMemo(() => groupByDay(rows, (row) => row.created_at), [rows]);
  const filtered = hasLibraryFilters(query);
  const activeCollection = page?.collection && page.collection.id === query.collection ? page.collection : collections.find((collection) => collection.id === query.collection);

  const retry = async (row: Row) => {
    if (!(await requestConsent())) return;
    try {
      await retryAudioTranscription(row.id);
      notifyLibraryActivityChanged();
      refresh();
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  const remove = async (row: Row) => {
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

  const setPreference = async (row: Row, changes: { favorite?: boolean; archived?: boolean }) => {
    try {
      await updateLibraryPreferences(normalizeItemType(row.item_type), row.id, changes);
      pageCache.clear();
      refresh();
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  const rowMenu = (row: Row): MenuItem[] => query.collection
    ? [
      { label: 'Remove from this collection', icon: <X />, onSelect: () => void (async () => {
        try { await removeCollectionItem(query.collection, row.collectionItemId ?? row.id); pageCache.clear(); refresh(); } catch (err) { setError(getErrorMessage(err)); }
      })() },
    ]
    : [
      { label: 'Add to collection', icon: <FolderPlus />, onSelect: () => setCollectionFor(row) },
      { label: row.favorite ? 'Unstar' : 'Star', icon: <Star />, onSelect: () => void setPreference(row, { favorite: !row.favorite }) },
      { label: row.archived ? 'Move out of archive' : 'Archive', icon: <Archive />, onSelect: () => void setPreference(row, { archived: !row.archived }) },
      { kind: 'separator' },
      { label: 'Delete', icon: <Trash2 />, tone: 'danger', onSelect: () => void remove(row) },
    ];

  const deleteActiveCollection = async () => {
    if (!activeCollection || !window.confirm(`Delete the collection “${activeCollection.name}”? The items in it stay in your library.`)) return;
    try {
      await deleteCollection(activeCollection.id);
      pageCache.clear();
      setQuery({ collection: '' });
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  return (
    <div className="mx-auto max-w-2xl pb-28 sm:pb-10">
      <div className="flex items-end justify-between gap-3 pt-2">
        <h1 className="text-large-title">{activeCollection ? activeCollection.name : 'Library'}</h1>
        {activeCollection && (
          <Menu
            label="Collection actions"
            trigger={<MoreHorizontal className="h-[22px] w-[22px]" />}
            items={[
              { label: 'Ask about this collection', icon: <MessageSquare />, onSelect: () => setAskingCollection(true) },
              { label: 'Rename', icon: <Pencil />, onSelect: () => setRenaming(true) },
              { kind: 'separator' },
              { label: 'Delete collection', icon: <Trash2 />, tone: 'danger', onSelect: () => void deleteActiveCollection() },
            ]}
          />
        )}
      </div>

      <form role="search" className="relative mt-3" onSubmit={(event) => { event.preventDefault(); setQuery({ q: searchInput }); }}>
        <Search className="pointer-events-none absolute left-3 top-1/2 h-[18px] w-[18px] -translate-y-1/2 text-text-secondary" aria-hidden="true" />
        <Input type="search" value={searchInput} onChange={(event) => setSearchInput(event.target.value)} placeholder={activeCollection ? 'Search this collection' : 'Search'} aria-label="Search your library" className="border-transparent pl-10 pr-11 [&::-webkit-search-cancel-button]:hidden" />
        {searchInput && (
          <button type="button" onClick={() => { setSearchInput(''); setQuery({ q: '' }); }} aria-label="Clear search" className="absolute right-0 top-0 flex h-11 w-11 items-center justify-center rounded-md text-text-secondary">
            <X className="h-4 w-4" />
          </button>
        )}
      </form>

      <div className="mt-2 flex min-h-11 items-center gap-1">
        <CollectionFilter collections={collections} value={query.collection} onChange={(collection) => setQuery({ collection, status: '', view: '' })} />
        {!query.collection && <FilterMenu query={query} onChange={setQuery} />}
        <div className="flex-1" />
        {page && <span className="text-callout text-text-secondary tabular">{pluralize(page.total, 'item')}</span>}
      </div>

      {filtered && (
        <p className="flex flex-wrap items-center gap-x-1 text-callout text-text-secondary">
          <span>{describeFilters(query, activeCollection?.name)}</span>
          <button type="button" onClick={() => { setSearchInput(''); setParams(serializeLibraryQuery(DEFAULT_LIBRARY_QUERY)); }} className="inline-flex min-h-11 items-center px-1 font-semibold text-accent">Clear</button>
        </p>
      )}

      {!filtered && failedCount > 0 && (
        <button type="button" onClick={() => setQuery({ status: 'failed' })} className="mt-1 flex min-h-11 items-center gap-2 text-callout">
          <AlertCircle className="h-4 w-4 text-text-secondary" aria-hidden="true" />
          <span>{failedCount === 1 ? '1 item needs attention' : `${failedCount} items need attention`}</span>
          <span className="font-semibold text-accent">Show</span>
        </button>
      )}

      {error && <div className="mt-3"><Notice tone="error" action={<Button variant="plain" onClick={refresh}>Try again</Button>}>{error}</Notice></div>}

      {!showing && !error ? (
        <LoadingRows />
      ) : rows.length === 0 && !error ? (
        <EmptyState filtered={filtered} inCollection={Boolean(query.collection)} onClear={() => { setSearchInput(''); setParams(new URLSearchParams()); }} />
      ) : (
        <div className="mt-1">
          {groups.map((group) => (
            <section key={group.key} aria-labelledby={`day-${group.key}`}>
              <h2 id={`day-${group.key}`} className="pb-1.5 pt-4 font-serif text-base font-semibold italic text-text-secondary">{group.label}</h2>
              <ul>
                {group.items.map((row) => <LibraryRow key={`${row.item_type}-${row.id}`} row={row} menu={rowMenu(row)} onRetry={() => void retry(row)} />)}
              </ul>
            </section>
          ))}
          {page && page.totalPages > 1 && (
            <nav className="mt-6 flex items-center justify-between" aria-label="Pages">
              <Button variant="plain" disabled={query.page <= 1} onClick={() => setQuery({ page: query.page - 1 })}>{query.sort === 'desc' ? 'Newer' : 'Earlier'}</Button>
              <span className="text-callout text-text-secondary tabular">Page {query.page} of {page.totalPages}</span>
              <Button variant="plain" disabled={query.page >= page.totalPages} onClick={() => setQuery({ page: query.page + 1 })}>{query.sort === 'desc' ? 'Older' : 'Later'}</Button>
            </nav>
          )}
        </div>
      )}

      <RecordBar />

      {collectionFor && (
        <AddToCollectionModal open onClose={() => setCollectionFor(null)} itemType={normalizeItemType(collectionFor.item_type)} itemId={collectionFor.id} itemTitle={collectionFor.title} onChanged={() => listCollections().then(setCollections).catch(() => undefined)} />
      )}
      {activeCollection && (
        <RenameCollectionDialog open={renaming} collection={activeCollection} onClose={() => setRenaming(false)} onRenamed={(updated) => { setCollections((list) => list.map((item) => item.id === updated.id ? { ...item, name: updated.name } : item)); pageCache.clear(); refresh(); }} />
      )}
      {activeCollection && (
        <Dialog open={askingCollection} onClose={() => setAskingCollection(false)} title={`Ask about ${activeCollection.name}`} size="lg">
          <ChatPanel itemType="collection" itemId={activeCollection.id} placeholder="Ask about this collection" autoFocus />
        </Dialog>
      )}
    </div>
  );
}

function LibraryRow({ row, menu, onRetry }: { row: Row; menu: MenuItem[]; onRetry: () => void }) {
  const attention = itemAttention(row);
  const meta = rowMeta(row);
  return (
    <li className="relative flex items-start gap-2 border-b border-separator py-3 last:border-b-0">
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-3">
          <Link to={itemDetailPath(row.item_type, row.id)} className="min-w-0 truncate text-row-title after:absolute after:inset-0 after:content-[''] focus-visible:outline-none [&:focus-visible]:after:rounded-sm [&:focus-visible]:after:outline-2 [&:focus-visible]:after:outline-accent">
            {displayTitle(row.title)}
          </Link>
          <span className="shrink-0 text-callout text-text-secondary tabular">{formatTimeOfDay(row.created_at)}</span>
        </div>
        <p className="mt-1 flex flex-wrap items-center gap-x-1.5 text-meta text-text-secondary">
          {row.favorite && <Star className="h-3 w-3 fill-current" aria-label="Starred" />}
          {meta && <span>{meta}</span>}
          {attention && (
            <>
              {meta && <span aria-hidden="true">·</span>}
              {attention.kind === 'processing' ? <Loader2 className="h-3 w-3 animate-spin" aria-hidden="true" /> : <AlertCircle className="h-3 w-3" aria-hidden="true" />}
              <span className={attention.kind === 'failed' ? 'text-text' : ''}>{attention.label}</span>
              {attention.kind === 'failed' && row.item_type === 'audio' && (
                <button type="button" onClick={onRetry} className="relative z-10 -my-3 inline-flex min-h-11 min-w-11 items-center justify-center px-1 font-semibold text-accent">Retry</button>
              )}
            </>
          )}
        </p>
      </div>
      {/* Rare actions stay off phones; on a desktop they sit behind one menu. */}
      <div className="relative z-10 -my-1 -mr-2 hidden md:block">
        <Menu label={`Actions for ${row.title}`} trigger={<MoreHorizontal className="h-5 w-5" />} triggerClassName="pressable inline-flex h-11 w-11 items-center justify-center rounded-full text-text-secondary hover:bg-fill" items={menu} />
      </div>
    </li>
  );
}

function rowMeta(row: Row): string {
  if (row.item_type === 'audio') return formatDuration(row.duration);
  if (row.item_type === 'pdf') return row.page_count ? `PDF · ${pluralize(row.page_count, 'page')}` : 'PDF';
  const channel = row.subtitle && row.subtitle !== 'Unknown channel' ? row.subtitle : '';
  return [channel, formatDuration(row.duration)].filter(Boolean).join(' · ') || 'Video';
}

function describeFilters(query: LibraryQuery, collectionName?: string): string {
  const parts: string[] = [];
  if (query.q.trim()) parts.push(`Matching “${query.q.trim()}”`);
  if (collectionName && !query.q.trim()) parts.push(`In ${collectionName}`);
  if (query.type) parts.push(query.type === 'audio' ? 'Recordings' : query.type === 'youtube' ? 'Videos' : 'PDFs');
  if (query.status === 'failed') parts.push('Needs attention');
  if (query.status === 'active') parts.push('Processing');
  if (query.status === 'completed') parts.push('Finished');
  if (query.view === 'favorites') parts.push('Starred');
  if (query.view === 'archive') parts.push('Archived');
  if (query.sort === 'asc') parts.push('Oldest first');
  return parts.join(' · ');
}

function CollectionFilter({ collections, value, onChange }: { collections: Collection[]; value: string; onChange: (id: string) => void }) {
  const selected = collections.find((collection) => collection.id === value);
  const items: MenuItem[] = [
    { label: 'All items', icon: value ? undefined : <Check />, onSelect: () => onChange('') },
    ...(collections.length ? [{ kind: 'separator' as const }] : []),
    ...collections.map((collection) => ({ label: collection.name, icon: collection.id === value ? <Check /> : undefined, onSelect: () => onChange(collection.id) })),
  ];
  return (
    <Menu
      label="Show a collection"
      align="start"
      triggerClassName="pressable -ml-2 inline-flex min-h-11 items-center gap-1 rounded-md px-2 text-callout font-medium text-accent hover:bg-fill"
      trigger={<><span className="max-w-[11rem] truncate">{selected ? selected.name : 'All collections'}</span><ChevronDown className="h-4 w-4" aria-hidden="true" /></>}
      items={items}
    />
  );
}

function FilterMenu({ query, onChange }: { query: LibraryQuery; onChange: (changes: Partial<LibraryQuery>) => void }) {
  const mark = (on: boolean) => (on ? <Check /> : undefined);
  return (
    <Menu
      label="Filter and sort"
      align="start"
      triggerClassName="pressable inline-flex min-h-11 items-center gap-1.5 rounded-md px-2 text-callout font-medium text-accent hover:bg-fill"
      trigger={<><SlidersHorizontal className="h-4 w-4" aria-hidden="true" />Filter</>}
      items={[
        { label: 'Everything', icon: mark(!query.type), onSelect: () => onChange({ type: '' }) },
        { label: 'Recordings', icon: mark(query.type === 'audio'), onSelect: () => onChange({ type: 'audio' }) },
        { label: 'Videos', icon: mark(query.type === 'youtube'), onSelect: () => onChange({ type: 'youtube' }) },
        { label: 'PDFs', icon: mark(query.type === 'pdf'), onSelect: () => onChange({ type: 'pdf' }) },
        { kind: 'separator' },
        { label: 'Starred', icon: mark(query.view === 'favorites'), onSelect: () => onChange({ view: query.view === 'favorites' ? '' : 'favorites' }) },
        { label: 'Archived', icon: mark(query.view === 'archive'), onSelect: () => onChange({ view: query.view === 'archive' ? '' : 'archive' }) },
        { label: 'Needs attention', icon: mark(query.status === 'failed'), onSelect: () => onChange({ status: query.status === 'failed' ? '' : 'failed' }) },
        { label: 'Processing', icon: mark(query.status === 'active'), onSelect: () => onChange({ status: query.status === 'active' ? '' : 'active' }) },
        { kind: 'separator' },
        { label: query.sort === 'asc' ? 'Newest first' : 'Oldest first', onSelect: () => onChange({ sort: query.sort === 'asc' ? 'desc' : 'asc' }) },
      ]}
    />
  );
}

function LoadingRows() {
  return (
    <div className="mt-4 space-y-5" role="status" aria-label="Loading your library">
      {Array.from({ length: 6 }, (_, index) => (
        <div key={index} className="space-y-2 border-b border-separator pb-4">
          <div className="h-4 rounded-sm bg-fill" style={{ width: `${70 - (index % 3) * 12}%` }} />
          <div className="h-3 w-24 rounded-sm bg-fill" />
        </div>
      ))}
    </div>
  );
}

function EmptyState({ filtered, inCollection, onClear }: { filtered: boolean; inCollection: boolean; onClear: () => void }) {
  if (filtered) {
    return (
      <div className="py-12">
        <p className="text-heading">{inCollection ? 'Nothing in this collection yet' : 'Nothing matches'}</p>
        <p className="mt-2 text-callout text-text-secondary">{inCollection ? 'Add items to it from their menu.' : 'Try other words, or clear the filters.'}</p>
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

/** One tap to record, at the thumb. Phones only; the desktop bar has Record. */
function RecordBar() {
  return (
    <div className="fixed inset-x-0 bottom-0 z-20 border-t border-separator bg-bar px-4 pb-[max(1rem,env(safe-area-inset-bottom))] pt-3 backdrop-blur-xl sm:hidden">
      <ButtonLink to={`${APP_ROUTES.add}?record=1`} variant="primary" size="lg" block icon={<Mic className="h-5 w-5" aria-hidden="true" />}>Record</ButtonLink>
    </div>
  );
}

function RenameCollectionDialog({ open, collection, onClose, onRenamed }: { open: boolean; collection: Collection; onClose: () => void; onRenamed: (collection: Collection) => void }) {
  const [name, setName] = useState(collection.name);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const save = async () => {
    if (!name.trim()) return;
    setBusy(true);
    setError('');
    try {
      onRenamed(await updateCollection(collection.id, { name: name.trim() }));
      onClose();
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog open={open} onClose={onClose} title="Rename collection" footer={<div className="flex justify-end gap-2"><Button onClick={onClose}>Cancel</Button><Button variant="primary" busy={busy} disabled={!name.trim()} onClick={() => void save()}>Save</Button></div>}>
      <form onSubmit={(event) => { event.preventDefault(); void save(); }}>
        <Input value={name} onChange={(event) => setName(event.target.value)} aria-label="Collection name" maxLength={100} autoFocus />
      </form>
      {error && <div className="mt-3"><Notice tone="error">{error}</Notice></div>}
    </Dialog>
  );
}
