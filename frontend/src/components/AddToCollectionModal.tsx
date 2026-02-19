import { useState, useEffect } from 'react';
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

  useEffect(() => {
    if (!open) return;
    setAdded(new Set());
    (async () => {
      setLoading(true);
      try {
        const data = await listCollections();
        setCollections(data);
      } catch { /* ignore */ }
      setLoading(false);
    })();
  }, [open]);

  const handleAdd = async (collectionId: string) => {
    setAdding(collectionId);
    try {
      await addCollectionItems(collectionId, [{ item_type: itemType, item_id: itemId }]);
      setAdded(prev => new Set(prev).add(collectionId));
    } catch { /* ignore, probably duplicate */ }
    setAdding(null);
  };

  const handleCreate = async () => {
    if (!newName.trim()) return;
    setCreating(true);
    try {
      const col = await createCollection(newName.trim());
      // Add item immediately
      await addCollectionItems(col.id, [{ item_type: itemType, item_id: itemId }]);
      setCollections(prev => [col, ...prev]);
      setAdded(prev => new Set(prev).add(col.id));
      setNewName('');
      setShowCreate(false);
    } catch { /* ignore */ }
    setCreating(false);
  };

  if (!open) return null;

  return (
    <AnimatePresence>
      <motion.div
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
              <h2 className="text-base font-semibold text-[var(--text-primary)] flex items-center gap-2">
                <FolderOpen className="w-4.5 h-4.5 text-[var(--brand)]" />
                Add to Collection
              </h2>
              {itemTitle && (
                <p className="text-xs text-[var(--text-tertiary)] mt-0.5 truncate max-w-[320px]">{itemTitle}</p>
              )}
            </div>
            <button onClick={onClose} className="p-1 rounded-md hover:bg-white/5 text-[var(--text-tertiary)]">
              <X className="w-4 h-4" />
            </button>
          </div>

          {/* Content */}
          <div className="p-2 max-h-80 overflow-y-auto">
            {loading ? (
              <div className="flex items-center justify-center py-10">
                <Loader2 className="w-5 h-5 animate-spin text-[var(--text-tertiary)]" />
              </div>
            ) : (
              <>
                {/* Create new inline */}
                {showCreate ? (
                  <div className="p-3 mb-1 rounded-lg bg-[var(--surface)]">
                    <input
                      autoFocus
                      value={newName}
                      onChange={e => setNewName(e.target.value)}
                      placeholder="Collection name..."
                      className="w-full bg-transparent text-sm text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none mb-2"
                      onKeyDown={e => e.key === 'Enter' && handleCreate()}
                    />
                    <div className="flex gap-2 justify-end">
                      <button onClick={() => setShowCreate(false)} className="text-xs text-[var(--text-secondary)]">Cancel</button>
                      <button
                        onClick={handleCreate}
                        disabled={!newName.trim() || creating}
                        className="text-xs px-3 py-1 rounded-md bg-[var(--brand)] text-white font-medium disabled:opacity-50 flex items-center gap-1.5"
                      >
                        {creating && <Loader2 className="w-3 h-3 animate-spin" />}
                        Create & Add
                      </button>
                    </div>
                  </div>
                ) : (
                  <button
                    onClick={() => setShowCreate(true)}
                    className="w-full flex items-center gap-2.5 p-3 rounded-lg text-sm text-[var(--brand)] hover:bg-[var(--brand)]/5 transition-colors mb-1"
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
                      className="w-full flex items-center gap-3 p-3 rounded-lg hover:bg-white/3 transition-colors text-left disabled:opacity-70"
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
