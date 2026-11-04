import { useEffect, useState, type FormEvent } from 'react';
import { Check, Loader2, Plus } from 'lucide-react';
import { addCollectionItems, createCollection, getErrorMessage, listCollections, type Collection } from '../lib/api';
import { Dialog } from './ui/Dialog';
import { Button } from './ui/Button';
import { Input, Notice } from './ui/Field';

interface Props {
  open: boolean;
  onClose: () => void;
  itemType: 'transcript' | 'audio' | 'pdf';
  itemId: string;
  itemTitle?: string;
  onChanged?: () => void;
}

/** Add one item to collections, or start a new collection with it. */
export function AddToCollectionModal({ open, onClose, itemType, itemId, itemTitle, onChanged }: Props) {
  const [collections, setCollections] = useState<Collection[]>([]);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState<string | null>(null);
  const [added, setAdded] = useState<Set<string>>(new Set());
  const [newName, setNewName] = useState('');
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!open) return;
    let current = true;
    queueMicrotask(() => { if (current) { setAdded(new Set()); setError(''); setLoading(true); } });
    listCollections()
      .then((data) => { if (current) setCollections(data); })
      .catch((err: unknown) => { if (current) setError(getErrorMessage(err)); })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [open]);

  const add = async (collectionId: string) => {
    setAdding(collectionId);
    setError('');
    try {
      await addCollectionItems(collectionId, [{ item_type: itemType, item_id: itemId }]);
      setAdded((previous) => new Set(previous).add(collectionId));
      onChanged?.();
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setAdding(null);
    }
  };

  const create = async (event: FormEvent) => {
    event.preventDefault();
    const name = newName.trim();
    if (!name) return;
    setCreating(true);
    setError('');
    try {
      const collection = await createCollection(name);
      await addCollectionItems(collection.id, [{ item_type: itemType, item_id: itemId }]);
      setCollections((previous) => [collection, ...previous]);
      setAdded((previous) => new Set(previous).add(collection.id));
      setNewName('');
      onChanged?.();
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setCreating(false);
    }
  };

  return (
    <Dialog open={open} onClose={onClose} title="Add to collection" footer={<Button variant="primary" block onClick={onClose}>Done</Button>}>
      {itemTitle && <p className="mb-3 truncate text-callout text-text-secondary">{itemTitle}</p>}
      {error && <div className="mb-3"><Notice tone="error">{error}</Notice></div>}
      {loading ? (
        <p className="flex min-h-11 items-center gap-2 text-callout text-text-secondary" role="status"><Loader2 className="h-4 w-4 animate-spin" />Loading collections…</p>
      ) : (
        <ul className="divide-y divide-separator">
          {collections.length === 0 && <li className="py-3 text-callout text-text-secondary">No collections yet. Name one below.</li>}
          {collections.map((collection) => {
            const isAdded = added.has(collection.id);
            return (
              <li key={collection.id}>
                <button type="button" onClick={() => void add(collection.id)} disabled={isAdded || adding === collection.id} className="flex min-h-12 w-full items-center gap-3 py-2 text-left disabled:cursor-default">
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-body font-medium">{collection.name}</span>
                    <span className="block text-meta text-text-secondary">{collection.item_count} {collection.item_count === 1 ? 'item' : 'items'}</span>
                  </span>
                  {adding === collection.id ? <Loader2 className="h-5 w-5 animate-spin text-text-secondary" /> : isAdded ? <span className="inline-flex items-center gap-1 text-meta font-semibold text-accent-text"><Check className="h-4 w-4" />Added</span> : <Plus className="h-5 w-5 text-accent-text" aria-label="Add" />}
                </button>
              </li>
            );
          })}
        </ul>
      )}
      <form onSubmit={(event) => void create(event)} className="mt-4 flex gap-2">
        <Input value={newName} onChange={(event) => setNewName(event.target.value)} placeholder="New collection name" aria-label="New collection name" maxLength={100} />
        <Button type="submit" busy={creating} disabled={!newName.trim()}>Create</Button>
      </form>
    </Dialog>
  );
}
