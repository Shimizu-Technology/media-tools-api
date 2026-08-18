import { useState, useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { motion } from 'framer-motion';
import {
  Search,
  ArrowUpDown,
  FileText,
  Clock,
  User,
  AlertCircle,
  X,
  ChevronLeft,
  ChevronRight,
  Youtube,
  Mic,
  FileType2,
  Sparkles,
  Loader2,
  Library,
  Trash2,
  CheckCircle2,
  Circle,
  FolderPlus,
  Star,
  Archive,
  RefreshCw,
  SlidersHorizontal,
} from 'lucide-react';
import { AddToCollectionModal } from '../components/AddToCollectionModal';
import {
  listLibraryItems,
  deleteTranscript,
  deleteAudioTranscription,
  deletePDFExtraction,
} from '../lib/api';
import { itemDetailPath } from '../lib/library';

type ContentType = 'all' | 'youtube' | 'audio' | 'pdf';
type StatusFilter = 'all' | 'completed' | 'processing' | 'failed';
type WorkspaceFilter = 'active' | 'favorites' | 'archive';

interface UnifiedItem {
  id: string;
  type: 'youtube' | 'audio' | 'pdf';
  title: string;
  subtitle: string;
  wordCount: number;
  status: string;
  hasSummary: boolean;
  createdAt: string;
  duration?: number;
  pageCount?: number;
  favorite: boolean;
  tags: string[];
}

/**
 * Unified library page showing all content types.
 * Replaces the old YouTube-only HistoryPage.
 */
export function MyLibraryPage() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  
  // Get a supported initial tab from the URL or default to all content.
  const requestedTab = searchParams.get('type');
  const initialTab: ContentType = requestedTab === 'youtube' || requestedTab === 'audio' || requestedTab === 'pdf'
    ? requestedTab
    : 'all';
  
  const activeTab = initialTab;
  const [items, setItems] = useState<UnifiedItem[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState('');
  const [searchQuery, setSearchQuery] = useState('');
  const [searchInput, setSearchInput] = useState('');
  const [sortDir, setSortDir] = useState<'desc' | 'asc'>('desc');
  const requestedStatus = searchParams.get('status');
  const statusFilter: StatusFilter = requestedStatus === 'completed' || requestedStatus === 'processing' || requestedStatus === 'failed' ? requestedStatus : 'all';
  const requestedView = searchParams.get('view');
  const workspaceFilter: WorkspaceFilter = requestedView === 'favorites' || requestedView === 'archive' ? requestedView : 'active';
  
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
	const [totalItems, setTotalItems] = useState(0);
  const perPage = 20;

  // Selection state for bulk delete
  const [selectedItems, setSelectedItems] = useState<Set<string>>(new Set());
  const [isDeleting, setIsDeleting] = useState(false);
  const [collectionModal, setCollectionModal] = useState<{ type: 'transcript' | 'audio' | 'pdf'; id: string; title: string } | null>(null);
  const [refreshToken, setRefreshToken] = useState(0);

  // Update URL when tab changes
  const handleTabChange = (tab: ContentType) => {
    setPage(1);
    const next: Record<string, string> = {};
    if (tab !== 'all') next.type = tab;
    if (statusFilter !== 'all') next.status = statusFilter;
    if (workspaceFilter !== 'active') next.view = workspaceFilter;
    setSearchParams(next);
  };

  const handleStatusChange = (status: StatusFilter) => {
    setPage(1);
    const next: Record<string, string> = {};
    if (activeTab !== 'all') next.type = activeTab;
    if (status !== 'all') next.status = status;
    if (workspaceFilter !== 'active') next.view = workspaceFilter;
    setSearchParams(next);
  };

  const handleWorkspaceFilterChange = (view: WorkspaceFilter) => {
    setPage(1);
    const next: Record<string, string> = {};
    if (activeTab !== 'all') next.type = activeTab;
    if (statusFilter !== 'all') next.status = statusFilter;
    if (view !== 'active') next.view = view;
    setSearchParams(next);
  };

  // Fetch one server-side page across every content type.
  useEffect(() => {
		let current = true;
		const timer = window.setTimeout(async () => {
      setIsLoading(true);
      setError('');
      try {
        const result = await listLibraryItems({ page, per_page: perPage, type: activeTab === 'all' ? undefined : activeTab, status: statusFilter === 'all' ? undefined : statusFilter, favorite: workspaceFilter === 'favorites' ? 'true' : undefined, archive: workspaceFilter === 'archive' ? 'only' : undefined, search: searchQuery || undefined, sort_dir: sortDir });
        if (!current) return;
        if (result.total_pages > 0 && page > result.total_pages) { setPage(result.total_pages); return; }
        setTotalPages(result.total_pages);
        setTotalItems(result.total_items);
        setItems(result.data.map((item) => ({ id: item.id, type: item.item_type, title: item.title, subtitle: item.item_type === 'audio' && item.duration > 0 ? `${item.subtitle} • ${formatDuration(item.duration)}` : item.subtitle, wordCount: item.word_count, status: item.status, hasSummary: item.summary_status === 'completed', createdAt: item.created_at, duration: item.duration, pageCount: item.page_count, favorite: item.favorite, tags: item.tags || [] })));
      } catch (err: unknown) {
        if (!current) return;
        console.error('Failed to load library:', err);
        setError("We couldn't load your library. Check your connection and try again.");
        setItems([]);
      } finally {
        if (current) setIsLoading(false);
      }
    }, 0);
		return () => { current = false; window.clearTimeout(timer); };
  }, [activeTab, page, searchQuery, sortDir, statusFilter, workspaceFilter, refreshToken]);

  // Debounced search
  useEffect(() => {
    const timer = setTimeout(() => {
      setSearchQuery(searchInput);
      setPage(1);
    }, 400);
    return () => clearTimeout(timer);
  }, [searchInput]);

	const filteredItems = items;
  const hasActiveFilters = activeTab !== 'all' || statusFilter !== 'all' || workspaceFilter !== 'active' || searchInput.trim() !== '';

  const clearFilters = () => {
    setSearchInput('');
    setSearchQuery('');
    setPage(1);
    setSearchParams({});
  };

  const handleItemClick = (item: UnifiedItem) => {
    // Don't navigate if in selection mode
    if (selectedItems.size > 0) {
      toggleSelection(item);
      return;
    }
    navigate(itemDetailPath(item.type, item.id));
  };

  const toggleSelection = (item: UnifiedItem) => {
    const key = `${item.type}-${item.id}`;
    setSelectedItems((prev) => {
      const newSet = new Set(prev);
      if (newSet.has(key)) {
        newSet.delete(key);
      } else {
        newSet.add(key);
      }
      return newSet;
    });
  };

  const handleDelete = async (item: UnifiedItem, e: React.MouseEvent) => {
    e.stopPropagation();
    if (!confirm(`Delete "${item.title}"?`)) return;
    
    setIsDeleting(true);
    try {
      switch (item.type) {
        case 'youtube':
          await deleteTranscript(item.id);
          break;
        case 'audio':
          await deleteAudioTranscription(item.id);
          break;
        case 'pdf':
          await deletePDFExtraction(item.id);
          break;
      }
		setRefreshToken((value) => value + 1);
    } catch {
      setError('Failed to delete item');
    }
    setIsDeleting(false);
  };

  const handleBulkDelete = async () => {
    if (!confirm(`Delete ${selectedItems.size} item(s)?`)) return;
    
    setIsDeleting(true);
	const toDelete = Array.from(selectedItems);
	const failed = new Set<string>();
    
    for (const key of toDelete) {
		const separator = key.indexOf('-');
		const type = key.slice(0, separator);
		const id = key.slice(separator + 1);
      try {
        switch (type) {
          case 'youtube':
            await deleteTranscript(id);
            break;
          case 'audio':
            await deleteAudioTranscription(id);
            break;
          case 'pdf':
            await deletePDFExtraction(id);
            break;
        }
      } catch (err) {
        console.error(`Failed to delete ${key}:`, err);
		failed.add(key);
      }
    }

	setRefreshToken((value) => value + 1);
	setSelectedItems(failed);
	if (failed.size > 0) {
		setError(`${failed.size} item${failed.size === 1 ? '' : 's'} could not be deleted. Please try again.`);
	}
    setIsDeleting(false);
  };

  const clearSelection = () => {
    setSelectedItems(new Set());
  };

  const formatDate = (dateStr: string): string => {
    return new Date(dateStr).toLocaleString('en-US', {
      month: 'long',
      day: 'numeric',
      year: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
    });
  };

  const statusColors: Record<string, { bg: string; text: string }> = {
    completed: { bg: 'var(--color-success-subtle)', text: 'var(--color-success)' },
    processing: { bg: 'var(--color-brand-50)', text: 'var(--color-brand-500)' },
    pending: { bg: 'var(--color-warning-subtle)', text: 'var(--color-warning)' },
    failed: { bg: 'var(--color-error-subtle)', text: 'var(--color-error)' },
  };

  const typeIcons: Record<string, React.ReactNode> = {
    youtube: <Youtube className="w-4 h-4" />,
    audio: <Mic className="w-4 h-4" />,
    pdf: <FileType2 className="w-4 h-4" />,
  };

  const typeColors: Record<string, { bg: string; text: string }> = {
    youtube: { bg: 'var(--color-error-subtle)', text: 'var(--color-error)' },
    audio: { bg: 'var(--color-brand-50)', text: 'var(--color-brand-500)' },
    pdf: { bg: 'var(--color-warning-subtle)', text: 'var(--color-warning)' },
  };

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="mx-auto max-w-5xl pb-12 sm:pb-16"
    >
      {/* Header */}
      <div className="mb-8">
        <div
          className="inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-medium mb-3"
          style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}
        >
          <Library className="w-3.5 h-3.5" />
          Workspace
        </div>
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="text-3xl sm:text-4xl font-semibold tracking-tight mb-2"
          style={{ color: 'var(--color-text-primary)' }}
        >
          My Library
        </motion.h1>
        <motion.p
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.1 }}
          style={{ color: 'var(--color-text-secondary)' }}
        >
          All your transcripts, recordings, and documents in one place.
        </motion.p>
      </div>

      {/* Selection Bar - shown when items are selected */}
      {selectedItems.size > 0 && (
        <motion.div
          initial={{ opacity: 0, y: -10 }}
          animate={{ opacity: 1, y: 0 }}
          className="mb-6 flex flex-col items-stretch justify-between gap-3 rounded-2xl p-4 sm:flex-row sm:items-center"
          style={{ backgroundColor: 'var(--color-error-subtle)', border: '1px solid var(--color-error-border)' }}
        >
          <div className="flex items-center gap-3">
            <span className="text-sm font-medium" style={{ color: 'var(--color-error)' }}>
              {selectedItems.size} selected
            </span>
            <button
              onClick={clearSelection}
              className="min-h-11 rounded-xl px-3 text-sm transition-colors"
              style={{ color: 'var(--color-text-muted)' }}
            >
              Clear
            </button>
          </div>
          <button
            onClick={handleBulkDelete}
            disabled={isDeleting}
            className="flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium text-white transition-colors disabled:opacity-50"
            style={{ backgroundColor: 'var(--color-error)', minHeight: '44px' }}
          >
            {isDeleting ? <Loader2 className="w-4 h-4 animate-spin" /> : <Trash2 className="w-4 h-4" />}
            Delete Selected
          </button>
        </motion.div>
      )}

      <div className="mb-4 grid grid-cols-3 gap-2" aria-label="Library view">
        {([
          { value: 'active', label: 'All items', icon: Library },
          { value: 'favorites', label: 'Starred', icon: Star },
          { value: 'archive', label: 'Archive', icon: Archive },
        ] as { value: WorkspaceFilter; label: string; icon: typeof Library }[]).map(({ value, label, icon: Icon }) => (
          <button key={value} onClick={() => handleWorkspaceFilterChange(value)} className="inline-flex min-h-11 min-w-0 items-center justify-center gap-1.5 rounded-xl border px-2 text-xs font-semibold sm:gap-2 sm:px-4 sm:text-sm" style={{ borderColor: workspaceFilter === value ? 'var(--color-brand-500)' : 'var(--color-border)', backgroundColor: workspaceFilter === value ? 'var(--color-brand-50)' : 'var(--color-surface-elevated)', color: workspaceFilter === value ? 'var(--color-brand-500)' : 'var(--color-text-secondary)' }}><Icon className="h-4 w-4 shrink-0" /><span className="truncate">{label}</span></button>
        ))}
      </div>

      {/* Search + compact filters */}
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.2 }}
        className="mb-6 space-y-3"
      >
        <div className="relative flex-1">
          <Search
            className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5"
            style={{ color: 'var(--color-text-muted)' }}
          />
          <input
            type="text"
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            placeholder="Search your library…"
            aria-label="Search your library"
            className="w-full pl-12 pr-10 py-3 rounded-xl border text-sm outline-none transition-colors"
            style={{
              backgroundColor: 'var(--color-surface-elevated)',
              borderColor: 'var(--color-border)',
              color: 'var(--color-text-primary)',
              minHeight: '44px',
            }}
          />
          {searchInput && (
            <button
              onClick={() => setSearchInput('')}
              className="absolute right-1 top-1/2 flex min-h-11 min-w-11 -translate-y-1/2 items-center justify-center rounded-lg"
              style={{ color: 'var(--color-text-muted)' }}
              aria-label="Clear search"
            >
              <X className="w-4 h-4" />
            </button>
          )}
        </div>

        <div className="grid grid-cols-2 gap-2 sm:flex sm:flex-wrap sm:items-center">
          <label className="relative min-w-0 sm:min-w-40">
            <span className="sr-only">Content type</span>
            <select
              value={activeTab}
              onChange={(event) => handleTabChange(event.target.value as ContentType)}
              className="min-h-11 w-full appearance-none rounded-xl border py-2 pl-4 pr-9 text-sm font-medium outline-none"
              style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}
            >
              <option value="all">All media</option>
              <option value="youtube">Video</option>
              <option value="audio">Recordings</option>
              <option value="pdf">PDFs</option>
            </select>
            <SlidersHorizontal className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2" style={{ color: 'var(--color-text-muted)' }} aria-hidden="true" />
          </label>

          <label className="relative min-w-0 sm:min-w-40">
            <span className="sr-only">Processing status</span>
            <select
              value={statusFilter}
              onChange={(event) => handleStatusChange(event.target.value as StatusFilter)}
              className="min-h-11 w-full appearance-none rounded-xl border py-2 pl-4 pr-9 text-sm font-medium capitalize outline-none"
              style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}
            >
              <option value="all">Any status</option>
              <option value="completed">Completed</option>
              <option value="processing">Processing</option>
              <option value="failed">Failed</option>
            </select>
            <SlidersHorizontal className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2" style={{ color: 'var(--color-text-muted)' }} aria-hidden="true" />
          </label>

          <button
            onClick={() => setSortDir(sortDir === 'desc' ? 'asc' : 'desc')}
            className="col-span-2 flex min-h-11 items-center justify-center gap-2 rounded-xl border px-4 py-2 text-sm font-medium transition-colors sm:col-auto"
            style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}
          >
            <ArrowUpDown className="h-4 w-4" />
            {sortDir === 'desc' ? 'Newest first' : 'Oldest first'}
          </button>

          {!isLoading && (
            <span className="col-span-2 px-1 text-sm sm:ml-auto" style={{ color: 'var(--color-text-muted)' }}>
              {totalItems.toLocaleString()} {totalItems === 1 ? 'item' : 'items'}
            </span>
          )}

          {hasActiveFilters && (
            <button
              onClick={clearFilters}
              className="col-span-2 inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-3 text-sm font-semibold sm:col-auto"
              style={{ color: 'var(--color-brand-500)' }}
            >
              <X className="h-4 w-4" />
              Clear filters
            </button>
          )}
        </div>
      </motion.div>

      {/* Loading */}
      {isLoading && (
        <div className="flex items-center justify-center py-16">
          <Loader2 className="w-8 h-8 animate-spin" style={{ color: 'var(--color-brand-500)' }} />
        </div>
      )}

      {/* Error */}
      {error && !isLoading && (
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          className="flex flex-col items-start gap-4 rounded-2xl border p-6 sm:flex-row sm:items-center"
          style={{
            backgroundColor: 'var(--color-error-soft)',
            borderColor: 'var(--color-error-border)',
          }}
        >
          <AlertCircle className="h-5 w-5 shrink-0" style={{ color: 'var(--color-error)' }} />
          <div className="flex-1">
            <p className="text-sm font-semibold" style={{ color: 'var(--color-error)' }}>Library unavailable</p>
            <p className="mt-1 text-sm" style={{ color: 'var(--color-text-secondary)' }}>{error}</p>
          </div>
          <button
            onClick={() => setRefreshToken((value) => value + 1)}
            className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold"
            style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-error-border)', color: 'var(--color-error)' }}
          >
            <RefreshCw className="h-4 w-4" />
            Try again
          </button>
        </motion.div>
      )}

      {/* Empty State */}
      {!isLoading && !error && filteredItems.length === 0 && (
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="text-center py-16"
        >
          <div
            className="w-16 h-16 rounded-2xl flex items-center justify-center mx-auto mb-4"
            style={{ backgroundColor: 'var(--color-surface-elevated)' }}
          >
            {activeTab === 'all' ? (
              <Library className="w-8 h-8" style={{ color: 'var(--color-text-muted)' }} />
            ) : activeTab === 'youtube' ? (
              <Youtube className="w-8 h-8" style={{ color: 'var(--color-text-muted)' }} />
            ) : activeTab === 'audio' ? (
              <Mic className="w-8 h-8" style={{ color: 'var(--color-text-muted)' }} />
            ) : (
              <FileType2 className="w-8 h-8" style={{ color: 'var(--color-text-muted)' }} />
            )}
          </div>
          <h3 className="text-lg font-semibold mb-2" style={{ color: 'var(--color-text-primary)' }}>
            {hasActiveFilters ? 'No items match these filters' : 'Your library is ready'}
          </h3>
          <p className="text-sm mb-6" style={{ color: 'var(--color-text-secondary)' }}>
            {hasActiveFilters
              ? 'Try a different search or clear the filters to see everything.'
              : 'Add a video transcript, recording, or PDF to keep it organized here.'}
          </p>
          {hasActiveFilters ? (
            <button
              onClick={clearFilters}
              className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-5 text-sm font-semibold"
              style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}
            >
              <X className="h-4 w-4" />
              Clear filters
            </button>
          ) : (
            <button
              onClick={() => navigate('/app/new')}
              className="inline-flex items-center gap-2 px-6 py-3 rounded-xl text-white font-medium text-sm"
              style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '44px' }}
            >
              <FileText className="h-4 w-4" />
              Add media
            </button>
          )}
        </motion.div>
      )}

      {/* Content Grid */}
      {!isLoading && filteredItems.length > 0 && (
        <motion.div
          initial="hidden"
          animate="visible"
          variants={{
            hidden: {},
            visible: { transition: { staggerChildren: 0.03 } },
          }}
          className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
        >
          {filteredItems.map((item) => {
            const colors = statusColors[item.status] || statusColors.pending;
            const isSelected = selectedItems.has(`${item.type}-${item.id}`);

            return (
              <motion.div
                key={`${item.type}-${item.id}`}
                variants={{
                  hidden: { opacity: 0, y: 20 },
                  visible: { opacity: 1, y: 0, transition: { duration: 0.3 } },
                }}
                onClick={() => handleItemClick(item)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' || event.key === ' ') {
                    event.preventDefault();
                    handleItemClick(item);
                  }
                }}
                role="link"
                tabIndex={0}
                className="group relative p-5 rounded-2xl border cursor-pointer transition-all duration-200 hover:scale-[1.01]"
                style={{
                  backgroundColor: isSelected ? 'var(--color-brand-50)' : 'var(--color-surface-elevated)',
                  borderColor: isSelected ? 'var(--color-brand-500)' : 'var(--color-border)',
                }}
              >
                {/* Selection checkbox - shown on hover or when items are selected */}
                <button
                  onClick={(e) => { e.stopPropagation(); toggleSelection(item); }}
				  className={`absolute top-2 left-2 flex min-h-11 min-w-11 items-center justify-center rounded-lg transition-opacity ${selectedItems.size > 0 ? 'opacity-100' : 'opacity-100 sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100'}`}
                  style={{ color: isSelected ? 'var(--color-brand-500)' : 'var(--color-text-muted)' }}
                  aria-label={isSelected ? `Deselect ${item.title}` : `Select ${item.title}`}
                >
                  {isSelected ? <CheckCircle2 className="w-5 h-5" /> : <Circle className="w-5 h-5" />}
                </button>

                {/* Type indicator + Delete button */}
                <div className="absolute top-4 right-4 flex items-center gap-1">
                  {/* Add to collection - shown on hover */}
                  <button
                    onClick={(e) => { e.stopPropagation(); setCollectionModal({ type: item.type === 'youtube' ? 'transcript' : item.type, id: item.id, title: item.title }); }}
					className="flex min-h-11 min-w-11 items-center justify-center rounded-lg opacity-100 sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100 transition-opacity"
                    style={{ color: 'var(--color-text-muted)' }}
                    title="Add to collection"
                    aria-label={`Add ${item.title} to a collection`}
                  >
                    <FolderPlus className="w-4 h-4" />
                  </button>
                  {/* Delete button - shown on hover */}
                  <button
                    onClick={(e) => handleDelete(item, e)}
					className="flex min-h-11 min-w-11 items-center justify-center rounded-lg opacity-100 sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100 transition-opacity"
                    style={{ color: 'var(--color-text-muted)' }}
                    title="Delete"
                    aria-label={`Delete ${item.title}`}
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                  <div
                    className="p-1.5 rounded-lg"
                    style={{ backgroundColor: typeColors[item.type].bg, color: typeColors[item.type].text }}
                    title={item.type.charAt(0).toUpperCase() + item.type.slice(1)}
                  >
                    {typeIcons[item.type]}
                  </div>
                </div>

                {/* Title */}
                <h3
                  className="text-sm font-semibold mb-1.5 pr-16 pl-6 line-clamp-2 leading-snug"
                  style={{ color: 'var(--color-text-primary)' }}
                >
                  {item.title}
                </h3>

                {/* Subtitle */}
                <div className="flex items-center gap-1.5 mb-3 pl-6">
                  {item.type === 'youtube' && <User className="w-3.5 h-3.5" style={{ color: 'var(--color-text-muted)' }} />}
                  <span className="text-xs truncate" style={{ color: 'var(--color-text-secondary)' }}>
                    {item.subtitle}
                  </span>
                </div>

                {/* Metadata row */}
                <div className="flex items-center gap-2 flex-wrap pl-6">
                  {/* Status badge */}
                  <span
                    className="inline-flex items-center px-2 py-0.5 rounded-md text-xs font-medium"
                    style={{ backgroundColor: colors.bg, color: colors.text }}
                  >
                    {item.status}
                  </span>

                  {/* Summary badge */}
                  {item.hasSummary && (
                    <span
                      className="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-xs font-medium"
                      style={{ backgroundColor: 'var(--color-summary-subtle)', color: 'var(--color-summary)' }}
                    >
                      <Sparkles className="w-3 h-3" />
                      Summarized
                    </span>
                  )}

                  {item.favorite && <span className="inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-medium" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}><Star className="h-3 w-3" /> Starred</span>}

                  {item.tags.slice(0, 2).map((tag) => <span key={tag} className="rounded-md px-2 py-0.5 text-xs" style={{ backgroundColor: 'var(--color-surface-subtle)', color: 'var(--color-text-secondary)' }}>{tag}</span>)}

                  {/* Date */}
                  <span className="flex items-center gap-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>
                    <Clock className="w-3 h-3" />
                    {formatDate(item.createdAt)}
                  </span>

                  {/* Word count */}
                  {item.wordCount > 0 && (
                    <span className="flex items-center gap-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>
                      <FileText className="w-3 h-3" />
                      {item.wordCount.toLocaleString()}
                    </span>
                  )}
                </div>
              </motion.div>
            );
          })}
        </motion.div>
      )}

	  {/* Pagination covers the unified result set for every tab. */}
	  {!isLoading && totalPages > 1 && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className="mt-8 grid grid-cols-[1fr_auto_1fr] items-center gap-2"
        >
          <button
            onClick={() => setPage((p) => Math.max(1, p - 1))}
            disabled={page === 1}
            className="flex min-h-11 items-center justify-center gap-1 rounded-xl border px-3 text-sm font-medium disabled:opacity-40 sm:px-4"
            style={{
              backgroundColor: 'var(--color-surface-elevated)',
              borderColor: 'var(--color-border)',
              color: 'var(--color-text-secondary)',
              minHeight: '44px',
            }}
          >
            <ChevronLeft className="w-4 h-4" />
            Previous
          </button>
          <span className="px-1 text-center text-xs sm:px-4 sm:text-sm" style={{ color: 'var(--color-text-muted)' }}>
            Page {page} of {totalPages}
          </span>
          <button
            onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
            disabled={page === totalPages}
            className="flex min-h-11 items-center justify-center gap-1 rounded-xl border px-3 text-sm font-medium disabled:opacity-40 sm:px-4"
            style={{
              backgroundColor: 'var(--color-surface-elevated)',
              borderColor: 'var(--color-border)',
              color: 'var(--color-text-secondary)',
              minHeight: '44px',
            }}
          >
            Next
            <ChevronRight className="w-4 h-4" />
          </button>
        </motion.div>
      )}
      {/* Add to Collection Modal */}
      <AddToCollectionModal
        open={!!collectionModal}
        onClose={() => setCollectionModal(null)}
        itemType={collectionModal?.type || 'transcript'}
        itemId={collectionModal?.id || ''}
        itemTitle={collectionModal?.title}
      />
    </motion.div>
  );
}

function formatDuration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}
