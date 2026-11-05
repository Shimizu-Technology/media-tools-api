import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ChevronRight, Folder, Plus } from 'lucide-react';
import { createCollection, getErrorMessage, listCollections, type Collection } from '../lib/api';
import { collectionPath } from '../lib/appRoutes';
import { collectionColorVar } from '../lib/collections';
import { pluralize } from '../lib/format';
import { Button, IconButton } from '../components/ui/Button';
import { Dialog } from '../components/ui/Dialog';
import { Input, Notice } from '../components/ui/Field';

/** Collections on their own page: group recordings, then ask across the group. */
export function CollectionsPage() {
  const navigate = useNavigate();
  const [collections, setCollections] = useState<Collection[] | null>(null);
  const [error, setError] = useState('');
  const [creating, setCreating] = useState(false);

  const load = useCallback(() => {
    listCollections()
      .then((list) => { setCollections(list); setError(''); })
      .catch((err: unknown) => setError(getErrorMessage(err)));
  }, []);
  useEffect(() => { load(); }, [load]);

  return (
    <div className="mx-auto max-w-3xl">
      <div className="flex items-center justify-between gap-3">
        <h1 className="text-large-title">Collections</h1>
        <IconButton label="New collection" className="-mr-2" onClick={() => setCreating(true)}><Plus className="h-6 w-6" /></IconButton>
      </div>
      <p className="mt-1 text-callout text-text-secondary">Group recordings, then ask questions across everything in the group.</p>

      {error && <div className="mt-3"><Notice tone="error" action={<Button variant="plain" onClick={load}>Try again</Button>}>{error}</Notice></div>}

      {collections === null ? (
        !error && <div className="mt-3 space-y-3" role="status" aria-label="Loading collections">{Array.from({ length: 4 }, (_, index) => <div key={index} className="h-12 rounded-md bg-fill" />)}</div>
      ) : collections.length === 0 ? (
        <div className="py-12">
          <p className="text-heading">No collections yet</p>
          <p className="mt-2 max-w-sm text-callout text-text-secondary">Make one for a project, a client, or anything you want to ask about as a group.</p>
          <Button className="mt-4" variant="primary" icon={<Plus className="h-4 w-4" />} onClick={() => setCreating(true)}>New collection</Button>
        </div>
      ) : (
        <ul className="mt-2">
          {collections.map((collection) => (
            <li key={collection.id} className="border-b border-separator last:border-b-0">
              <Link to={collectionPath(collection.id)} className="flex min-h-[4.25rem] items-center gap-3 py-3 hover:opacity-80">
                <CollectionTile color={collection.color} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-row-title">{collection.name}</span>
                  <span className="block font-mono text-meta text-text-secondary">{pluralize(collection.item_count, 'item')}</span>
                </span>
                <ChevronRight className="h-5 w-5 shrink-0 text-text-secondary" aria-hidden="true" />
              </Link>
            </li>
          ))}
        </ul>
      )}

      <NewCollectionDialog open={creating} onClose={() => setCreating(false)} onCreated={(collection) => navigate(collectionPath(collection.id))} />
    </div>
  );
}

export function CollectionTile({ color }: { color?: string }) {
  return (
    <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-md text-on-hero" style={{ backgroundColor: collectionColorVar(color) }}>
      <Folder className="h-[22px] w-[22px]" aria-hidden="true" />
    </span>
  );
}

function NewCollectionDialog({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: (collection: Collection) => void }) {
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const create = async () => {
    if (!name.trim() || busy) return;
    setBusy(true);
    setError('');
    try {
      onCreated(await createCollection(name.trim()));
    } catch (err) {
      setError(getErrorMessage(err));
      setBusy(false);
    }
  };
  return (
    <Dialog open={open} onClose={onClose} title="New collection" footer={<div className="flex justify-end gap-2"><Button onClick={onClose}>Cancel</Button><Button variant="primary" busy={busy} disabled={!name.trim()} onClick={() => void create()}>Create</Button></div>}>
      <form onSubmit={(event) => { event.preventDefault(); void create(); }}>
        <Input value={name} onChange={(event) => setName(event.target.value)} aria-label="Collection name" placeholder="Name" maxLength={100} data-autofocus />
      </form>
      {error && <div className="mt-3"><Notice tone="error">{error}</Notice></div>}
    </Dialog>
  );
}
