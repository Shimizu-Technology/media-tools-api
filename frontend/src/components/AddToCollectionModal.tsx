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
        <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" />

        {/* Modal */}
        <motion.div
          initial={{ opacity: 0, scale: 0.95, y: 8 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          exit={{ opacity: 0, scale: 0.95 }}
          onClick={e => e.stopPropagation()}
          className="relative w-full max-w-md rounded-2xl border border-[var(--border)] bg-[var(--bg)] shadow-2xl overflow-hidden"
        >
          {/* Header */}
          <div className="flex items-center justify-between p-4 border-b border-[var(--border)]">
            <div>
				<h2 id="add-to-collection-title" className="text-base font-semibold text-[var(--text-primary)] flex items-center gap-2">
                <FolderOpen className="w-4.5 h-4.5 text-[var(--brand)]" />
                Add to Collection
              </h2>
              {itemTitle && (
                <p className="text-xs text-[var(--text-tertiary)] mt-0.5 truncate max-w-[320px]">{itemTitle}</p>
              )}
            </div>
			<button onClick={onClose} aria-label="Close dialog" className="flex min-h-11 min-w-11 items-center justify-center rounded-md hover:bg-[var(--color-nav-hover)] text-[var(--text-tertiary)]">
              <X className="w-4 h-4" />
            </button>
          </div>

          {/* Content */}
		  <div className="p-2 max-h-80 overflow-y-auto">
			{error && <p role="alert" className="m-2 rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-500">{error}</p>}
            {loading ? (
              <div className="flex items-center justify-center py-10">
                <Loader2 className="w-5 h-5 animate-spin text-[var(--text-tertiary)]" />
              </div>
            ) : (
              <>
                {/* Create new inline */}
                {showCreate ? (
                  <div className="mb-1 rounded-xl bg-[var(--surface)] p-3">
                    <input
                      autoFocus
                      value={newName}
                      onChange={e => setNewName(e.target.value)}
                      placeholder="Collection name..."
                      className="mb-2 min-h-11 w-full rounded-lg border border-[var(--border)] bg-transparent px-3 text-base text-[var(--text-primary)] outline-none placeholder:text-[var(--text-tertiary)]"
                      onKeyDown={e => e.key === 'Enter' && handleCreate()}
                    />
                    <div className="grid grid-cols-2 gap-2 sm:flex sm:justify-end">
                      <button onClick={() => setShowCreate(false)} className="min-h-11 rounded-lg px-3 text-sm text-[var(--text-secondary)] hover:bg-[var(--color-nav-hover)]">Cancel</button>
                      <button
                        onClick={handleCreate}
                        disabled={!newName.trim() || creating}
                        className="flex min-h-11 items-center justify-center gap-1.5 rounded-lg bg-[var(--brand)] px-3 text-sm font-medium text-white disabled:opacity-50"
                      >
                        {creating && <Loader2 className="w-3 h-3 animate-spin" />}
                        Create & Add
                      </button>
                    </div>
                  </div>
                ) : (
                  <button
                    onClick={() => setShowCreate(true)}
                    className="mb-1 flex min-h-11 w-full items-center gap-2.5 rounded-lg p-3 text-sm text-[var(--brand)] transition-colors hover:bg-[var(--brand)]/5"
                  >
                    <Plus className="w-4 h-4" />
                    New Collection
                  </button>
                )}

                {/* Existing collections */}
                {collections.length === 0 && !showCreate && (
                  <p className="text-center text-sm text-[var(--text-tertiary)] py-6">No collections yet</p>
                )}
                {collections.map(col => {
                  const isAdded = added.has(col.id);
                  const isAdding = adding === col.id;
                  return (
                    <button
                      key={col.id}
                      onClick={() => !isAdded && handleAdd(col.id)}
                      disabled={isAdded || isAdding}
                      className="flex min-h-14 w-full items-center gap-3 rounded-lg p-3 text-left transition-colors hover:bg-white/3 disabled:opacity-70"
                    >
                      <div className="w-8 h-8 rounded-md bg-[var(--brand)]/10 flex items-center justify-center shrink-0">
                        <FolderOpen className="w-4 h-4 text-[var(--brand)]" />
                      </div>
                      <div className="flex-1 min-w-0">
                        <span className="text-sm font-medium text-[var(--text-primary)] truncate block">{col.name}</span>
                        <span className="text-xs text-[var(--text-tertiary)]">
                          {col.item_count} {col.item_count === 1 ? 'item' : 'items'}
                        </span>
                      </div>
                      {isAdding ? (
                        <Loader2 className="w-4 h-4 animate-spin text-[var(--text-tertiary)]" />
                      ) : isAdded ? (
                        <Check className="w-4 h-4 text-emerald-400" />
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
