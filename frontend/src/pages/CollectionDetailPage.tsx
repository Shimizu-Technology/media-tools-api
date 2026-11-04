import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, Navigate, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { ChevronLeft, MessageSquare, MoreHorizontal, Pencil, Search, Trash2, X } from 'lucide-react';
import { deleteCollection, getCollection, getErrorMessage, removeCollectionItem, updateCollection, type Collection, type CollectionItem, type CollectionWithItems, type LibraryItem } from '../lib/api';
import { APP_ROUTES } from '../lib/appRoutes';
import { isCollectionId } from '../lib/collections';
import { pluralize } from '../lib/format';
import { parseLibraryQuery, type LibraryType } from '../lib/libraryQuery';
import { ChatPanel } from '../components/ChatPanel';
import { ItemRow, LoadingRows } from '../components/library/ItemRow';
import { Button } from '../components/ui/Button';
import { Dialog } from '../components/ui/Dialog';
import { Input, Notice } from '../components/ui/Field';
import { Menu } from '../components/ui/Menu';
import { CollectionTile } from './CollectionsPage';

type Row = LibraryItem & { collectionItemId: string };

function toRow(entry: CollectionItem): Row {
  return {
    id: entry.item_id,
    collectionItemId: entry.id,
    item_type: entry.item_type === 'transcript' ? 'youtube' : entry.item_type,
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
  };
}

const TYPE_FILTERS: { value: LibraryType; label: string }[] = [
  { value: '', label: 'All' },
  { value: 'audio', label: 'Recordings' },
  { value: 'youtube', label: 'Links' },
  { value: 'pdf', label: 'PDFs' },
];

/** One collection: its items, a question across all of them, and its management. */
export function CollectionDetailPage() {
  const { collectionId } = useParams();
  if (!isCollectionId(collectionId)) return <Navigate to={APP_ROUTES.collections} replace />;
  return <CollectionDetail key={collectionId} id={collectionId} />;
}

function CollectionDetail({ id }: { id: string }) {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const { q, type } = useMemo(() => parseLibraryQuery(params), [params]);
  const [collection, setCollection] = useState<CollectionWithItems | null>(null);
  const [error, setError] = useState('');
  const [loadFailed, setLoadFailed] = useState(false);
  const [dialog, setDialog] = useState<'rename' | 'ask' | null>(null);

  const load = useCallback(() => {
    getCollection(id)
      .then((value) => { setCollection(value); setError(''); setLoadFailed(false); })
      .catch((err: unknown) => { setError(getErrorMessage(err)); setLoadFailed(true); });
  }, [id]);
  useEffect(() => { load(); }, [load]);

  const setFilter = (changes: { q?: string; type?: LibraryType }) => {
    const next = new URLSearchParams();
    const nextQ = changes.q ?? q;
    const nextType = changes.type ?? type;
    if (nextQ) next.set('q', nextQ);
    if (nextType) next.set('type', nextType);
    setParams(next, { replace: 'q' in changes });
  };

  const rows = useMemo(() => {
    const needle = q.trim().toLocaleLowerCase();
    return (collection?.items ?? [])
      .map(toRow)
      .filter((row) => !needle || row.title.toLocaleLowerCase().includes(needle))
      .filter((row) => !type || row.item_type === type);
  }, [collection, q, type]);

  const removeItem = async (row: Row) => {
    try {
      await removeCollectionItem(id, row.collectionItemId);
      load();
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  const remove = async () => {
    if (!collection || !window.confirm(`Delete the collection “${collection.name}”? The items in it stay in your library.`)) return;
    try {
      await deleteCollection(id);
      navigate(APP_ROUTES.collections, { replace: true });
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  const total = collection?.items.length ?? 0;

  return (
    <div className="mx-auto max-w-3xl">
      <Link to={APP_ROUTES.collections} className="pressable -ml-2 inline-flex min-h-11 items-center gap-0.5 rounded-md pr-3 text-body text-accent-text hover:bg-fill">
        <ChevronLeft className="h-6 w-6" aria-hidden="true" />Collections
      </Link>

      {loadFailed && !collection ? (
        <div className="py-12">
          <p className="text-title">This collection could not be opened</p>
          <p className="mt-2 text-callout text-text-secondary">{error}</p>
          <Button className="mt-4" onClick={load}>Try again</Button>
        </div>
      ) : !collection ? (
        <LoadingRows label="Loading this collection" />
      ) : (
        <>
          <div className="mt-1 flex items-center gap-3">
            <CollectionTile color={collection.color} />
            <div className="min-w-0 flex-1">
              <h1 className="break-words text-title">{collection.name}</h1>
              <p className="font-mono text-meta text-text-secondary">{pluralize(total, 'item')}</p>
            </div>
            <Menu
              label="Collection actions"
              trigger={<MoreHorizontal className="h-[22px] w-[22px]" />}
              items={[
                { label: 'Ask about this collection', icon: <MessageSquare />, onSelect: () => setDialog('ask') },
                { label: 'Rename', icon: <Pencil />, onSelect: () => setDialog('rename') },
                { kind: 'separator' },
                { label: 'Delete collection', icon: <Trash2 />, tone: 'danger', onSelect: () => void remove() },
              ]}
            />
          </div>

          {total > 0 && (
            <>
              <Button variant="primary" block className="mt-3" icon={<MessageSquare className="h-4 w-4" />} onClick={() => setDialog('ask')}>Ask about this collection</Button>
              <div role="search" className="relative mt-3">
                <Search className="pointer-events-none absolute left-3 top-1/2 h-[18px] w-[18px] -translate-y-1/2 text-text-secondary" aria-hidden="true" />
                <Input type="search" value={q} onChange={(event) => setFilter({ q: event.target.value })} placeholder="Search this collection" aria-label="Search this collection" className="pl-10 pr-11 [&::-webkit-search-cancel-button]:hidden" />
                {q && <button type="button" onClick={() => setFilter({ q: '' })} aria-label="Clear search" className="absolute right-0 top-0 flex h-11 w-11 items-center justify-center rounded-md text-text-secondary"><X className="h-4 w-4" /></button>}
              </div>
              <div className="no-scrollbar -mx-4 mt-1 flex gap-1.5 overflow-x-auto px-4 md:mx-0 md:px-0" role="group" aria-label="Show">
                {TYPE_FILTERS.map((filter) => (
                  <button key={filter.label} type="button" aria-pressed={type === filter.value} onClick={() => setFilter({ type: filter.value })} className="pressable flex min-h-11 shrink-0 items-center">
                    <span className={`inline-flex h-8 items-center rounded-full px-3 text-meta font-semibold transition-colors ${type === filter.value ? 'bg-accent-fill text-on-accent' : 'bg-surface-2 text-text-secondary'}`}>{filter.label}</span>
                  </button>
                ))}
              </div>
            </>
          )}

          {error && <div className="mt-3"><Notice tone="error">{error}</Notice></div>}

          {total === 0 ? (
            <div className="py-12">
              <p className="text-heading">Nothing in this collection yet</p>
              <p className="mt-2 text-callout text-text-secondary">Add items from their menu in the Library, or from the item’s page.</p>
            </div>
          ) : rows.length === 0 ? (
            <div className="py-12">
              <p className="text-heading">Nothing matches</p>
              <Button className="mt-4" onClick={() => setParams(new URLSearchParams())}>Show everything</Button>
            </div>
          ) : (
            <ul>
              {rows.map((row) => (
                <ItemRow key={row.collectionItemId} item={row} from={collection.name} alwaysShowMenu menu={[{ label: 'Remove from this collection', icon: <X />, onSelect: () => void removeItem(row) }]} />
              ))}
            </ul>
          )}

          <RenameCollectionDialog open={dialog === 'rename'} collection={collection} onClose={() => setDialog(null)} onRenamed={(updated) => setCollection((value) => value && { ...value, name: updated.name })} />
          <Dialog open={dialog === 'ask'} onClose={() => setDialog(null)} title={`Ask about ${collection.name}`} size="lg">
            <ChatPanel itemType="collection" itemId={collection.id} placeholder="Ask about this collection" autoFocus />
          </Dialog>
        </>
      )}
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
