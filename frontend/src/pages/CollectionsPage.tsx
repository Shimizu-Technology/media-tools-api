import { useState, useEffect, useCallback } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import {
  FolderOpen,
  Plus,
  Pencil,
  Trash2,
  ArrowLeft,
  FileText,
  Mic,
  FileType2,
  Youtube,
  X,
  Loader2,
  AlertCircle,
  GripVertical,
  MessageSquare,
} from 'lucide-react';
import { TranscriptChatPanel } from '../components/TranscriptChatPanel';
import {
  listCollections,
  createCollection,
  getCollection,
  updateCollection,
  deleteCollection,
  removeCollectionItem,
  type Collection,
  type CollectionWithItems,
  type CollectionItem,
} from '../lib/api';

const itemTypeIcons: Record<string, typeof FileText> = {
  transcript: Youtube,
  audio: Mic,
  pdf: FileType2,
};

const itemTypeLabels: Record<string, string> = {
  transcript: 'Video Transcript',
  audio: 'Audio Recording',
  pdf: 'PDF Document',
};

const itemTypeColors: Record<string, string> = {
  transcript: 'text-red-400',
  audio: 'text-amber-400',
  pdf: 'text-blue-400',
};

/** Collections listing + detail (two-panel via route param). */
export function CollectionsPage() {
  const { collectionId } = useParams();
  return collectionId ? <CollectionDetail id={collectionId} /> : <CollectionsList />;
}

// ─── Collections List ───

function CollectionsList() {
  const navigate = useNavigate();
  const [collections, setCollections] = useState<Collection[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [showCreate, setShowCreate] = useState(false);
  const [newName, setNewName] = useState('');
  const [newDesc, setNewDesc] = useState('');
  const [creating, setCreating] = useState(false);
  const [editId, setEditId] = useState<string | null>(null);
  const [editName, setEditName] = useState('');
  const [editDesc, setEditDesc] = useState('');

  const load = useCallback(async () => {
    try {
      setLoading(true);
      const data = await listCollections();
      setCollections(data);
    } catch {
      setError('Failed to load collections');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const handleCreate = async () => {
    if (!newName.trim()) return;
    setCreating(true);
    try {
      await createCollection(newName.trim(), newDesc.trim());
      setNewName('');
      setNewDesc('');
      setShowCreate(false);
      load();
    } catch {
      setError('Failed to create collection');
    } finally {
      setCreating(false);
    }
  };

  const handleUpdate = async (id: string) => {
    try {
      await updateCollection(id, { name: editName, description: editDesc });
      setEditId(null);
      load();
    } catch {
      setError('Failed to update collection');
    }
  };

  const handleDelete = async (id: string) => {
    if (!confirm('Delete this collection? Items inside won\u2019t be deleted.')) return;
    try {
      await deleteCollection(id);
      load();
    } catch {
      setError('Failed to delete collection');
    }
  };

  return (
    <div className="mx-auto max-w-4xl">
      {/* Header */}
      <div className="mb-8 flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
        <div className="min-w-0">
          <div className="mb-3 inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.18em]" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
            <FolderOpen className="h-3.5 w-3.5" /> Workspace
          </div>
          <h1 className="flex items-center gap-3 text-3xl font-semibold tracking-tight text-[var(--text-primary)] sm:text-4xl">
            Collections
          </h1>
          <p className="mt-2 max-w-xl text-sm leading-6 text-[var(--text-secondary)]">
            Group transcripts, recordings, and documents together
          </p>
        </div>
        <button
          onClick={() => setShowCreate(true)}
          className="flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-[var(--brand)] px-4 text-sm font-semibold text-white transition-all hover:brightness-110 sm:w-auto"
        >
          <Plus className="w-4 h-4" />
          New Collection
        </button>
      </div>

      {/* Error */}
      <AnimatePresence>
        {error && (
          <motion.div
            initial={{ opacity: 0, y: -8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0 }}
            className="flex items-center gap-2 p-3 mb-4 rounded-lg bg-red-500/10 text-red-400 text-sm"
          >
            <AlertCircle className="w-4 h-4 shrink-0" />
            <span className="min-w-0 flex-1">{error}</span>
            <button onClick={() => setError('')} className="ml-auto flex min-h-11 min-w-11 items-center justify-center rounded-lg" aria-label="Dismiss error"><X className="w-4 h-4" /></button>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Create form */}
      <AnimatePresence>
        {showCreate && (
          <motion.div
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={{ opacity: 0, height: 0 }}
            className="overflow-hidden mb-6"
          >
            <div className="rounded-2xl border border-[var(--border)] bg-[var(--surface)] p-4 sm:p-5">
              <input
                autoFocus
                value={newName}
                onChange={e => setNewName(e.target.value)}
                placeholder="Collection name..."
                className="mb-3 min-h-11 w-full rounded-xl border border-[var(--border)] bg-[var(--color-surface-subtle)] px-3 text-base font-semibold text-[var(--text-primary)] outline-none placeholder:text-[var(--text-tertiary)]"
                onKeyDown={e => e.key === 'Enter' && handleCreate()}
              />
              <input
                value={newDesc}
                onChange={e => setNewDesc(e.target.value)}
                placeholder="Description (optional)"
                className="mb-4 min-h-11 w-full rounded-xl border border-[var(--border)] bg-[var(--color-surface-subtle)] px-3 text-base text-[var(--text-secondary)] outline-none placeholder:text-[var(--text-tertiary)] sm:text-sm"
              />
              <div className="flex gap-2 justify-end">
                <button
                  onClick={() => { setShowCreate(false); setNewName(''); setNewDesc(''); }}
                  className="min-h-11 rounded-xl px-4 text-sm font-medium text-[var(--text-secondary)] transition-colors hover:bg-[var(--color-nav-hover)] hover:text-[var(--text-primary)]"
                >
                  Cancel
                </button>
                <button
                  onClick={handleCreate}
                  disabled={!newName.trim() || creating}
                  className="flex min-h-11 items-center gap-2 rounded-xl bg-[var(--brand)] px-4 text-sm font-semibold text-white disabled:opacity-50"
                >
                  {creating && <Loader2 className="w-3.5 h-3.5 animate-spin" />}
                  Create
                </button>
              </div>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Loading */}
      {loading ? (
        <div className="flex items-center justify-center py-20 text-[var(--text-tertiary)]">
          <Loader2 className="w-6 h-6 animate-spin" />
        </div>
      ) : collections.length === 0 ? (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className="text-center py-20"
        >
          <FolderOpen className="w-12 h-12 text-[var(--text-tertiary)] mx-auto mb-4" />
          <p className="text-[var(--text-secondary)] mb-1">No collections yet</p>
          <p className="text-sm text-[var(--text-tertiary)]">
            Create one to start organizing your content
          </p>
        </motion.div>
      ) : (
        <div className="space-y-3">
          {collections.map((col, i) => (
            <motion.div
              key={col.id}
              initial={{ opacity: 0, y: 12 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: i * 0.04 }}
              className="group rounded-2xl border border-[var(--border)] bg-[var(--surface)] transition-all hover:border-[var(--brand)]/30"
            >
              {editId === col.id ? (
                <div className="p-4 sm:p-5">
                  <input
                    autoFocus
                    value={editName}
                    onChange={e => setEditName(e.target.value)}
                    className="mb-2 min-h-11 w-full rounded-xl border border-[var(--border)] bg-[var(--color-surface-subtle)] px-3 text-base font-semibold text-[var(--text-primary)] outline-none"
                    onKeyDown={e => e.key === 'Enter' && handleUpdate(col.id)}
                  />
                  <input
                    value={editDesc}
                    onChange={e => setEditDesc(e.target.value)}
                    placeholder="Description"
                    className="mb-3 min-h-11 w-full rounded-xl border border-[var(--border)] bg-[var(--color-surface-subtle)] px-3 text-base text-[var(--text-secondary)] outline-none sm:text-sm"
                  />
                  <div className="flex gap-2 justify-end">
                    <button onClick={() => setEditId(null)} className="min-h-11 rounded-xl px-4 text-sm font-medium text-[var(--text-secondary)] hover:bg-[var(--color-nav-hover)]">Cancel</button>
                    <button onClick={() => handleUpdate(col.id)} className="min-h-11 rounded-xl bg-[var(--brand)] px-4 text-sm font-semibold text-white">Save</button>
                  </div>
                </div>
              ) : (
                <div
                  className="flex min-h-20 cursor-pointer flex-wrap items-center gap-3 p-4 sm:flex-nowrap sm:gap-4"
                  onClick={() => navigate(`/app/collections/${col.id}`)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' || event.key === ' ') navigate(`/app/collections/${col.id}`);
                  }}
                  role="link"
                  tabIndex={0}
                >
                  <div className="w-10 h-10 rounded-lg bg-[var(--brand)]/10 flex items-center justify-center shrink-0">
                    <FolderOpen className="w-5 h-5 text-[var(--brand)]" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <h3 className="font-medium text-[var(--text-primary)] truncate">{col.name}</h3>
                    {col.description && (
                      <p className="text-sm text-[var(--text-tertiary)] truncate">{col.description}</p>
                    )}
                  </div>
                  <span className="shrink-0 text-xs tabular-nums text-[var(--text-tertiary)]">
                    {col.item_count} {col.item_count === 1 ? 'item' : 'items'}
                  </span>
                  <div className="flex gap-1 opacity-100 sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100 transition-opacity" onClick={e => e.stopPropagation()}>
                    <button
                      onClick={() => { setEditId(col.id); setEditName(col.name); setEditDesc(col.description); }}
                      className="flex min-h-11 min-w-11 items-center justify-center rounded-lg hover:bg-white/5 text-[var(--text-tertiary)] hover:text-[var(--text-primary)]"
                      aria-label={`Edit ${col.name}`}
                    >
                      <Pencil className="w-3.5 h-3.5" />
                    </button>
                    <button
                      onClick={() => handleDelete(col.id)}
                      className="flex min-h-11 min-w-11 items-center justify-center rounded-lg hover:bg-red-500/10 text-[var(--text-tertiary)] hover:text-red-400"
                      aria-label={`Delete ${col.name}`}
                    >
                      <Trash2 className="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              )}
            </motion.div>
          ))}
        </div>
      )}
    </div>
  );
}

// ─── Collection Detail ───

function CollectionDetail({ id }: { id: string }) {
  const [collection, setCollection] = useState<CollectionWithItems | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [removing, setRemoving] = useState<string | null>(null);
  const [showChat, setShowChat] = useState(false);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      const data = await getCollection(id);
      setCollection(data);
    } catch {
      setError('Collection not found');
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => { load(); }, [load]);

  const handleRemoveItem = async (itemId: string) => {
    setRemoving(itemId);
    try {
      await removeCollectionItem(id, itemId);
      load();
    } catch {
      setError('Failed to remove item');
    } finally {
      setRemoving(null);
    }
  };

  const getItemLink = (item: CollectionItem) => {
    switch (item.item_type) {
      case 'transcript': return `/app/items/transcript/${item.item_id}`;
      case 'audio': return `/app/items/audio/${item.item_id}`;
      case 'pdf': return `/app/items/pdf/${item.item_id}`;
      default: return '/app/library';
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="w-6 h-6 animate-spin text-[var(--text-tertiary)]" />
      </div>
    );
  }

  if (error || !collection) {
    return (
      <div className="mx-auto max-w-4xl py-20 text-center">
        <AlertCircle className="w-10 h-10 text-red-400 mx-auto mb-3" />
        <p className="text-[var(--text-secondary)]">{error || 'Not found'}</p>
        <Link to="/app/collections" className="mt-2 inline-flex min-h-11 items-center rounded-xl px-3 text-sm text-[var(--brand)] hover:bg-[var(--color-nav-hover)]">
          Back to collections
        </Link>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-4xl">
      {/* Back + header */}
      <Link
        to="/app/collections"
        className="mb-4 inline-flex min-h-11 items-center gap-1.5 rounded-xl pr-3 text-sm text-[var(--text-tertiary)] transition-colors hover:text-[var(--text-primary)]"
      >
        <ArrowLeft className="w-4 h-4" />
        All Collections
      </Link>

      <div className="mb-8 rounded-[2rem] border border-[var(--border)] bg-[var(--surface)] p-5 sm:p-7">
        <h1 className="flex min-w-0 items-start gap-3 text-2xl font-semibold tracking-tight text-[var(--text-primary)] sm:text-3xl">
          <FolderOpen className="mt-1 h-7 w-7 shrink-0 text-[var(--brand)]" />
          <span className="min-w-0 break-words">{collection.name}</span>
        </h1>
        {collection.description && (
          <p className="text-sm text-[var(--text-secondary)] mt-1">{collection.description}</p>
        )}
        <div className="mt-3 flex flex-col gap-3 sm:flex-row sm:items-center">
          <p className="text-xs text-[var(--text-tertiary)]">
            {collection.items.length} {collection.items.length === 1 ? 'item' : 'items'}
          </p>
          {collection.items.length > 0 && (
            <button
              onClick={() => setShowChat(!showChat)}
              className={`flex min-h-11 w-full items-center justify-center gap-1.5 rounded-xl px-3 text-sm font-medium transition-all sm:ml-auto sm:w-auto ${
                showChat
                  ? 'bg-[var(--brand)] text-white'
                  : 'bg-[var(--brand)]/10 text-[var(--brand)] hover:bg-[var(--brand)]/20'
              }`}
            >
              <MessageSquare className="w-3.5 h-3.5" />
              {showChat ? 'Hide Chat' : 'Chat with AI'}
            </button>
          )}
        </div>
      </div>

      {/* Items */}
      {collection.items.length === 0 ? (
        <div className="rounded-2xl border border-dashed border-[var(--border)] px-5 py-16 text-center">
          <GripVertical className="w-8 h-8 text-[var(--text-tertiary)] mx-auto mb-3 rotate-90" />
          <p className="text-[var(--text-secondary)] mb-1">No items in this collection</p>
          <p className="text-sm text-[var(--text-tertiary)]">
            Use the &ldquo;Add to Collection&rdquo; button on any item in your library
          </p>
        </div>
      ) : (
        <div className="space-y-2">
          {collection.items.map((item, i) => {
            const Icon = itemTypeIcons[item.item_type] || FileText;
            const colorClass = itemTypeColors[item.item_type] || 'text-gray-400';
            return (
              <motion.div
                key={item.id}
                initial={{ opacity: 0, x: -8 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ delay: i * 0.03 }}
                className="group flex min-h-20 items-center gap-3 rounded-2xl border border-[var(--border)] bg-[var(--surface)] p-3 transition-all hover:border-[var(--brand)]/20 sm:p-4"
              >
                <Icon className={`w-4.5 h-4.5 shrink-0 ${colorClass}`} />
                <div className="flex-1 min-w-0">
                  <Link
                    to={getItemLink(item)}
                    className="text-sm font-medium text-[var(--text-primary)] hover:text-[var(--brand)] truncate block transition-colors"
                  >
                    {item.item_title || `${itemTypeLabels[item.item_type]} — ${item.item_id.slice(0, 8)}`}
                  </Link>
                  <span className="text-xs text-[var(--text-tertiary)]">
                    {itemTypeLabels[item.item_type]}
                    {item.item_status && ` · ${item.item_status}`}
                  </span>
                </div>
                <button
                  onClick={() => handleRemoveItem(item.id)}
                  disabled={removing === item.id}
                  className="flex min-h-11 min-w-11 items-center justify-center rounded-lg opacity-100 sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100 hover:bg-red-500/10 text-[var(--text-tertiary)] hover:text-red-400 transition-all disabled:opacity-50"
                  aria-label={`Remove ${item.item_title || 'item'} from ${collection.name}`}
                >
                  {removing === item.id ? (
                    <Loader2 className="w-3.5 h-3.5 animate-spin" />
                  ) : (
                    <Trash2 className="w-3.5 h-3.5" />
                  )}
                </button>
              </motion.div>
            );
          })}
        </div>
      )}

      {/* Collection AI Chat */}
      <AnimatePresence>
        {showChat && (
          <motion.div
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={{ opacity: 0, height: 0 }}
            className="overflow-hidden mt-8"
          >
            <div className="overflow-hidden rounded-2xl border border-[var(--border)]">
              <TranscriptChatPanel itemId={id} itemType="collection" />
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
