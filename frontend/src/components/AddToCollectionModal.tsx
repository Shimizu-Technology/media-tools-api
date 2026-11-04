import { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import {
  FolderOpen,
  Plus,
  Check,
  X,
  Loader2,
} from 'lucide-react';
import {
  listCollections,
  createCollection,
  addCollectionItems,
  type Collection,
} from '../lib/api';

interface Props {
  open: boolean;
  onClose: () => void;
  itemType: 'transcript' | 'audio' | 'pdf';
  itemId: string;
  itemTitle?: string;
}

/**
 * Modal for adding an item to one or more collections.
 * Shows existing collections with checkmarks, plus inline create.
 */
export function AddToCollectionModal({ open, onClose, itemType, itemId, itemTitle }: Props) {
  const [collections, setCollections] = useState<Collection[]>([]);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState<string | null>(null);
  const [added, setAdded] = useState<Set<string>>(new Set());
  const [showCreate, setShowCreate] = useState(false);
  const [newName, setNewName] = useState('');
  const [creating, setCreating] = useState(false);
	const [error, setError] = useState('');
	const dialogRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
		queueMicrotask(() => { setAdded(new Set()); setError(''); });
    (async () => {
      setLoading(true);
      try {
        const data = await listCollections();
        setCollections(data);
		} catch (err: unknown) {
			setError((err as { message?: string }).message || 'Could not load collections.');
		}
      setLoading(false);
    })();
  }, [open]);

	useEffect(() => {
		if (!open) return;
		const onKeyDown = (event: KeyboardEvent) => {
			if (event.key === 'Escape') onClose();
			if (event.key !== 'Tab' || !dialogRef.current) return;
			const focusable = Array.from(dialogRef.current.querySelectorAll<HTMLElement>('button:not([disabled]), input:not([disabled])'));
			if (focusable.length === 0) return;
			const first = focusable[0];
			const last = focusable[focusable.length - 1];
			if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
			else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
		};
		document.addEventListener('keydown', onKeyDown);
		window.setTimeout(() => dialogRef.current?.querySelector<HTMLElement>('button')?.focus(), 0);
		return () => document.removeEventListener('keydown', onKeyDown);
	}, [open, onClose]);

  const handleAdd = async (collectionId: string) => {
		setAdding(collectionId);
		setError('');
    try {
      await addCollectionItems(collectionId, [{ item_type: itemType, item_id: itemId }]);
      setAdded(prev => new Set(prev).add(collectionId));
		} catch (err: unknown) {
			setError((err as { message?: string }).message || 'Could not add this item to the collection.');
		}
    setAdding(null);
  };

  const handleCreate = async () => {
    if (!newName.trim()) return;
		setCreating(true);
		setError('');
    try {
      const col = await createCollection(newName.trim());
      // Add item immediately
      await addCollectionItems(col.id, [{ item_type: itemType, item_id: itemId }]);
      setCollections(prev => [col, ...prev]);
      setAdded(prev => new Set(prev).add(col.id));
      setNewName('');
      setShowCreate(false);
		} catch (err: unknown) {
			setError((err as { message?: string }).message || 'Could not create the collection.');
		}
    setCreating(false);
  };

  if (!open) return null;

  return (
    <AnimatePresence>
		<motion.div
			ref={dialogRef}
			role="dialog"
			aria-modal="true"
			aria-labelledby="add-to-collection-title"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        className="fixed inset-0 z-50 flex items-center justify-center p-4"
        onClick={onClose}
      >
        {/* Backdrop */}
        <div className="absolute inset-0 bg-scrim backdrop-blur-sm" />

        {/* Modal */}
        <motion.div
          initial={{ opacity: 0, scale: 0.95, y: 8 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          exit={{ opacity: 0, scale: 0.95 }}
          onClick={e => e.stopPropagation()}
          className="relative w-full max-w-md rounded-lg border border-[var(--color-separator)] bg-[var(--color-bg)] shadow-overlay overflow-hidden"
        >
          {/* Header */}
          <div className="flex items-center justify-between p-4 border-b border-[var(--color-separator)]">
            <div>
				<h2 id="add-to-collection-title" className="text-base font-semibold text-[var(--color-text)] flex items-center gap-2">
                <FolderOpen className="w-4.5 h-4.5 text-[var(--color-accent)]" />
                Add to Collection
              </h2>
              {itemTitle && (
                <p className="text-xs text-[var(--color-text-secondary)] mt-0.5 truncate max-w-[320px]">{itemTitle}</p>
              )}
            </div>
			<button onClick={onClose} aria-label="Close dialog" className="flex min-h-11 min-w-11 items-center justify-center rounded-sm hover:bg-[var(--color-fill)] text-[var(--color-text-secondary)]">
              <X className="w-4 h-4" />
            </button>
          </div>

          {/* Content */}
		  <div className="p-2 max-h-80 overflow-y-auto">
			{error && <p role="alert" className="m-2 rounded-sm border border-separator bg-fill px-3 py-2 text-sm text-danger">{error}</p>}
            {loading ? (
              <div className="flex items-center justify-center py-10">
                <Loader2 className="w-5 h-5 animate-spin text-[var(--color-text-secondary)]" />
              </div>
            ) : (
              <>
                {/* Create new inline */}
                {showCreate ? (
                  <div className="mb-1 rounded-md bg-[var(--color-surface)] p-3">
                    <input
                      autoFocus
                      value={newName}
                      onChange={e => setNewName(e.target.value)}
                      placeholder="Collection name..."
                      className="mb-2 min-h-11 w-full rounded-sm border border-[var(--color-separator)] bg-transparent px-3 text-base text-[var(--color-text)] outline-none placeholder:text-[var(--color-text-secondary)]"
                      onKeyDown={e => e.key === 'Enter' && handleCreate()}
                    />
                    <div className="grid grid-cols-2 gap-2 sm:flex sm:justify-end">
                      <button onClick={() => setShowCreate(false)} className="min-h-11 rounded-sm px-3 text-sm text-[var(--color-text-secondary)] hover:bg-[var(--color-fill)]">Cancel</button>
                      <button
                        onClick={handleCreate}
                        disabled={!newName.trim() || creating}
                        className="flex min-h-11 items-center justify-center gap-1.5 rounded-sm bg-accent-fill px-3 text-sm font-medium text-on-accent disabled:opacity-50"
                      >
                        {creating && <Loader2 className="w-3 h-3 animate-spin" />}
                        Create & Add
                      </button>
                    </div>
                  </div>
                ) : (
                  <button
                    onClick={() => setShowCreate(true)}
                    className="mb-1 flex min-h-11 w-full items-center gap-2.5 rounded-sm p-3 text-sm text-[var(--color-accent)] transition-colors hover:bg-accent-fill/5"
                  >
                    <Plus className="w-4 h-4" />
                    New Collection
                  </button>
                )}

                {/* Existing collections */}
                {collections.length === 0 && !showCreate && (
                  <p className="text-center text-sm text-[var(--color-text-secondary)] py-6">No collections yet</p>
                )}
                {collections.map(col => {
                  const isAdded = added.has(col.id);
                  const isAdding = adding === col.id;
                  return (
                    <button
                      key={col.id}
                      onClick={() => !isAdded && handleAdd(col.id)}
                      disabled={isAdded || isAdding}
                      className="flex min-h-14 w-full items-center gap-3 rounded-sm p-3 text-left transition-colors hover:bg-fill disabled:opacity-70"
                    >
                      <div className="w-8 h-8 rounded-sm bg-accent-fill/10 flex items-center justify-center shrink-0">
                        <FolderOpen className="w-4 h-4 text-[var(--color-accent)]" />
                      </div>
                      <div className="flex-1 min-w-0">
                        <span className="text-sm font-medium text-[var(--color-text)] truncate block">{col.name}</span>
                        <span className="text-xs text-[var(--color-text-secondary)]">
                          {col.item_count} {col.item_count === 1 ? 'item' : 'items'}
                        </span>
                      </div>
                      {isAdding ? (
                        <Loader2 className="w-4 h-4 animate-spin text-[var(--color-text-secondary)]" />
                      ) : isAdded ? (
                        <Check className="w-4 h-4 text-accent" />
                      ) : null}
                    </button>
                  );
                })}
              </>
            )}
          </div>
        </motion.div>
      </motion.div>
    </AnimatePresence>
  );
}
