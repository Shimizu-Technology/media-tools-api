import { useState, useEffect, useCallback, useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Search,
  Filter,
  ArrowUpDown,
  Trash2,
  Download,
  FileText,
  Clock,
  User,
  CheckSquare,
  Square,
  AlertCircle,
  X,
  ChevronLeft,
  ChevronRight,
} from 'lucide-react';
import {
  listTranscripts,
  getStoredTranscriptIds,
  removeTranscriptsFromHistory,
  type Transcript,
  type PaginatedResponse,
} from '../lib/api';

/**
 * MTA-13: History / Dashboard page.
 * Lists past transcriptions with search, filter, sort, and bulk actions.
 * Works without auth — stores transcript IDs in localStorage, fetches from API.
 */
export function HistoryPage() {
  const navigate = useNavigate();
  const [transcripts, setTranscripts] = useState<Transcript[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState('');
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('');
  const [sortBy, setSortBy] = useState<string>('created_at');
  const [sortDir, setSortDir] = useState<string>('desc');
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [showFilters, setShowFilters] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  const perPage = 12;

  const fetchTranscripts = useCallback(async () => {
    setIsLoading(true);
    setError('');
    try {
      const result: PaginatedResponse<Transcript> = await listTranscripts({
        page,
        per_page: perPage,
        status: statusFilter || undefined,
        search: searchQuery || undefined,
      });
      setTranscripts(result.data);
      setTotalPages(result.total_pages);
      setTotalItems(result.total_items);
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to load transcripts');
      setTranscripts([]);
    }
    setIsLoading(false);
  }, [page, statusFilter, searchQuery]);

  useEffect(() => {
    queueMicrotask(() => {
      void fetchTranscripts();
    });
  }, [fetchTranscripts]);

  // Client-side sorting (API supports it too but we sort what we have for responsiveness)
  const sortedTranscripts = useMemo(() => {
    const sorted = [...transcripts];
    sorted.sort((a, b) => {
      let cmp = 0;
      switch (sortBy) {
        case 'title':
          cmp = (a.title || '').localeCompare(b.title || '');
          break;
        case 'word_count':
          cmp = a.word_count - b.word_count;
          break;
        case 'created_at':
        default:
          cmp = new Date(a.created_at).getTime() - new Date(b.created_at).getTime();
          break;
      }
      return sortDir === 'desc' ? -cmp : cmp;
    });
    return sorted;
  }, [transcripts, sortBy, sortDir]);

  const toggleSelect = (id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const selectAll = () => {
    if (selectedIds.size === sortedTranscripts.length) {
      setSelectedIds(new Set());
    } else {
      setSelectedIds(new Set(sortedTranscripts.map((t) => t.id)));
    }
  };

  const handleBulkDelete = async () => {
    if (selectedIds.size === 0) return;
    setIsDeleting(true);
    removeTranscriptsFromHistory([...selectedIds]);
    setSelectedIds(new Set());
    await fetchTranscripts();
    setIsDeleting(false);
  };

  const handleExportSelected = () => {
    const selected = sortedTranscripts.filter((t) => selectedIds.has(t.id));
    const exportData = selected.map((t) => ({
      title: t.title,
      channel: t.channel_name,
      url: t.youtube_url,
      transcript: t.transcript_text,
      word_count: t.word_count,
      created_at: t.created_at,
    }));
    const blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `transcripts-export-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const formatDate = (dateStr: string): string => {
    return new Date(dateStr).toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    });
  };

  const statusColors: Record<string, { bg: string; text: string; border: string }> = {
    completed: {
      bg: 'rgba(24, 185, 133, 0.12)',
      text: 'var(--color-accent)',
      border: 'rgba(24, 185, 133, 0.24)',
    },
    processing: {
      bg: 'var(--color-accent-tint)',
      text: 'var(--color-accent)',
      border: 'rgba(47, 158, 143, 0.24)',
    },
    pending: {
      bg: 'rgba(245, 158, 11, 0.1)',
      text: '#f59e0b',
      border: 'rgba(245, 158, 11, 0.2)',
    },
    failed: {
      bg: 'rgba(239, 68, 68, 0.12)',
      text: 'var(--color-danger)',
      border: 'rgba(239, 68, 68, 0.24)',
    },
  };

  // Debounced search
  const [searchInput, setSearchInput] = useState('');
  useEffect(() => {
    const timer = setTimeout(() => {
      setSearchQuery(searchInput);
      setPage(1);
    }, 400);
    return () => clearTimeout(timer);
  }, [searchInput]);

  const storedIds = getStoredTranscriptIds();
  const hasHistory = storedIds.length > 0 || transcripts.length > 0;

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.3 }}
      className="max-w-5xl mx-auto px-4 sm:px-6 pt-24 pb-16"
    >
      {/* Page Header */}
      <div className="mb-8">
        <div
          className="inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-medium mb-3"
          style={{ backgroundColor: 'var(--color-accent-tint)', color: 'var(--color-accent)' }}
        >
          <FileText className="w-3.5 h-3.5" />
          Archive
        </div>
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
          className="text-3xl sm:text-4xl font-semibold tracking-tight mb-2"
          style={{ color: 'var(--color-text)' }}
        >
          Transcript History
        </motion.h1>
        <motion.p
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
          style={{ color: 'var(--color-text-secondary)' }}
        >
          {totalItems > 0
            ? `${totalItems} transcript${totalItems !== 1 ? 's' : ''} found`
            : 'Browse and manage your extracted transcripts.'}
        </motion.p>
      </div>

      {/* Search + Filters Bar */}
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, delay: 0.15, ease: [0.22, 1, 0.36, 1] }}
        className="mb-6 space-y-3"
      >
        <div className="flex flex-col sm:flex-row gap-3">
          {/* Search Input */}
          <div className="relative flex-1">
            <Search
              className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5"
              style={{ color: 'var(--color-text-secondary)' }}
            />
            <input
              type="text"
              value={searchInput}
              onChange={(e) => setSearchInput(e.target.value)}
              placeholder="Search by title or channel..."
              className="w-full pl-12 pr-4 py-3 rounded-md border text-sm outline-none transition-colors duration-200"
              style={{
                backgroundColor: 'var(--color-surface)',
                borderColor: 'var(--color-separator)',
                color: 'var(--color-text)',
                minHeight: '44px',
              }}
            />
            {searchInput && (
              <button
                onClick={() => setSearchInput('')}
                className="absolute right-3 top-1/2 -translate-y-1/2 p-1 rounded-sm hover:opacity-80"
                style={{ color: 'var(--color-text-secondary)' }}
              >
                <X className="w-4 h-4" />
              </button>
            )}
          </div>

          {/* Filter Toggle */}
          <button
            onClick={() => setShowFilters(!showFilters)}
            className="flex items-center gap-2 px-4 py-3 rounded-md border text-sm font-medium transition-colors duration-200"
            style={{
              backgroundColor: showFilters ? 'var(--color-accent)' : 'var(--color-surface)',
              borderColor: showFilters ? 'var(--color-accent)' : 'var(--color-separator)',
              color: showFilters ? 'white' : 'var(--color-text-secondary)',
              minHeight: '44px',
            }}
          >
            <Filter className="w-4 h-4" />
            Filters
          </button>

          {/* Sort Toggle */}
          <button
            onClick={() => setSortDir(sortDir === 'desc' ? 'asc' : 'desc')}
            className="flex items-center gap-2 px-4 py-3 rounded-md border text-sm font-medium transition-colors duration-200"
            style={{
              backgroundColor: 'var(--color-surface)',
              borderColor: 'var(--color-separator)',
              color: 'var(--color-text-secondary)',
              minHeight: '44px',
            }}
          >
            <ArrowUpDown className="w-4 h-4" />
            {sortDir === 'desc' ? 'Newest' : 'Oldest'}
          </button>
        </div>

        {/* Filter Options (collapsible) */}
        <AnimatePresence>
          {showFilters && (
            <motion.div
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: 'auto' }}
              exit={{ opacity: 0, height: 0 }}
              transition={{ duration: 0.2 }}
              className="overflow-hidden"
            >
              <div
                className="flex flex-wrap gap-3 p-4 rounded-md border"
                style={{
                  backgroundColor: 'var(--color-surface)',
                  borderColor: 'var(--color-separator)',
                }}
              >
                <div className="space-y-1.5">
                  <label className="text-xs font-medium" style={{ color: 'var(--color-text-secondary)' }}>
                    Status
                  </label>
                  <div className="flex gap-2">
                    {['', 'completed', 'processing', 'pending', 'failed'].map((s) => (
                      <button
                        key={s}
                        onClick={() => { setStatusFilter(s); setPage(1); }}
                        className="px-3 py-1.5 rounded-sm text-xs font-medium transition-colors duration-200"
                        style={{
                          backgroundColor: statusFilter === s ? 'var(--color-accent)' : 'var(--color-bg)',
                          color: statusFilter === s ? 'white' : 'var(--color-text-secondary)',
                          border: `1px solid ${statusFilter === s ? 'var(--color-accent)' : 'var(--color-separator)'}`,
                        }}
                      >
                        {s || 'All'}
                      </button>
                    ))}
                  </div>
                </div>

                <div className="space-y-1.5">
                  <label className="text-xs font-medium" style={{ color: 'var(--color-text-secondary)' }}>
                    Sort by
                  </label>
                  <div className="flex gap-2">
                    {[
                      { value: 'created_at', label: 'Date' },
                      { value: 'title', label: 'Title' },
                      { value: 'word_count', label: 'Words' },
                    ].map((opt) => (
                      <button
                        key={opt.value}
                        onClick={() => setSortBy(opt.value)}
                        className="px-3 py-1.5 rounded-sm text-xs font-medium transition-colors duration-200"
                        style={{
                          backgroundColor: sortBy === opt.value ? 'var(--color-accent)' : 'var(--color-bg)',
                          color: sortBy === opt.value ? 'white' : 'var(--color-text-secondary)',
                          border: `1px solid ${sortBy === opt.value ? 'var(--color-accent)' : 'var(--color-separator)'}`,
                        }}
                      >
                        {opt.label}
                      </button>
                    ))}
                  </div>
                </div>
              </div>
            </motion.div>
          )}
        </AnimatePresence>

        {/* Bulk Actions */}
        <AnimatePresence>
          {selectedIds.size > 0 && (
            <motion.div
              initial={{ opacity: 0, y: -10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -10 }}
              className="flex items-center gap-3 p-3 rounded-md border"
              style={{
                backgroundColor: 'var(--color-surface)',
                borderColor: 'var(--color-accent)',
              }}
            >
              <span className="text-sm font-medium" style={{ color: 'var(--color-text)' }}>
                {selectedIds.size} selected
              </span>
              <div className="flex gap-2 ml-auto">
                <button
                  onClick={handleExportSelected}
                  className="flex items-center gap-1.5 px-3 py-1.5 rounded-sm text-sm font-medium transition-colors duration-200"
                  style={{
                    backgroundColor: 'var(--color-bg)',
                    border: '1px solid var(--color-separator)',
                    color: 'var(--color-text-secondary)',
                    minHeight: '36px',
                  }}
                >
                  <Download className="w-3.5 h-3.5" />
                  Export
                </button>
                <button
                  onClick={handleBulkDelete}
                  disabled={isDeleting}
                  className="flex items-center gap-1.5 px-3 py-1.5 rounded-sm text-sm font-medium transition-colors duration-200"
                  style={{
                    backgroundColor: 'rgba(239, 68, 68, 0.12)',
                    border: '1px solid rgba(239, 68, 68, 0.24)',
                    color: 'var(--color-danger)',
                    minHeight: '36px',
                  }}
                >
                  <Trash2 className="w-3.5 h-3.5" />
                  {isDeleting ? 'Removing...' : 'Remove'}
                </button>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </motion.div>

      {/* Select All toggle */}
      {sortedTranscripts.length > 0 && (
        <div className="flex items-center gap-2 mb-4">
          <button
            onClick={selectAll}
            className="flex items-center gap-2 text-sm transition-colors duration-200"
            style={{ color: 'var(--color-text-secondary)', minHeight: '44px' }}
          >
            {selectedIds.size === sortedTranscripts.length ? (
              <CheckSquare className="w-4 h-4" style={{ color: 'var(--color-accent)' }} />
            ) : (
              <Square className="w-4 h-4" />
            )}
            Select all
          </button>
        </div>
      )}

      {/* Loading State — Shimmer Skeletons */}
      {isLoading && (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {Array.from({ length: 6 }).map((_, i) => (
            <div
              key={i}
              className="p-5 rounded-lg border"
              style={{
                backgroundColor: 'var(--color-surface)',
                borderColor: 'var(--color-separator)',
              }}
            >
              <div className="space-y-3">
                <div
                  className="h-5 rounded-sm relative overflow-hidden"
                  style={{ backgroundColor: 'var(--color-separator)', width: '75%' }}
                >
                  <div className="absolute inset-0 -translate-x-full animate-[shimmer_2s_infinite] bg-linear-to-r from-transparent via-fill to-transparent" />
                </div>
                <div
                  className="h-4 rounded-sm relative overflow-hidden"
                  style={{ backgroundColor: 'var(--color-separator)', width: '50%' }}
                >
                  <div className="absolute inset-0 -translate-x-full animate-[shimmer_2s_infinite] bg-linear-to-r from-transparent via-fill to-transparent" />
                </div>
                <div className="flex gap-3 pt-2">
                  <div
                    className="h-3 rounded-sm"
                    style={{ backgroundColor: 'var(--color-separator)', width: '60px' }}
                  />
                  <div
                    className="h-3 rounded-sm"
                    style={{ backgroundColor: 'var(--color-separator)', width: '80px' }}
                  />
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Error State */}
      {error && !isLoading && (
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          className="flex items-center gap-3 p-6 rounded-lg border text-center"
          style={{
            backgroundColor: 'rgba(239, 68, 68, 0.08)',
            borderColor: 'rgba(239, 68, 68, 0.24)',
          }}
        >
          <AlertCircle className="w-5 h-5 shrink-0" style={{ color: 'var(--color-danger)' }} />
          <p className="text-sm" style={{ color: 'var(--color-danger)' }}>{error}</p>
        </motion.div>
      )}

      {/* Empty State */}
      {!isLoading && !error && sortedTranscripts.length === 0 && (
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="text-center py-16"
        >
          <div
            className="w-16 h-16 rounded-lg flex items-center justify-center mx-auto mb-4"
            style={{ backgroundColor: 'var(--color-surface)' }}
          >
            <FileText className="w-8 h-8" style={{ color: 'var(--color-text-secondary)' }} />
          </div>
          <h3 className="text-lg font-semibold mb-2" style={{ color: 'var(--color-text)' }}>
            {hasHistory ? 'No results found' : 'No transcripts yet'}
          </h3>
          <p className="text-sm mb-6" style={{ color: 'var(--color-text-secondary)' }}>
            {hasHistory
              ? 'Try adjusting your search or filters'
              : 'Extract your first video transcript to see it here'}
          </p>
          {!hasHistory && (
            <button
              onClick={() => navigate('/app/video')}
              className="inline-flex items-center gap-2 px-6 py-3 rounded-md text-on-accent font-medium text-sm transition-colors hover:opacity-90"
              style={{ backgroundColor: 'var(--color-accent-fill)', minHeight: '44px' }}
            >
              <FileText className="w-4 h-4" />
              Extract a transcript
            </button>
          )}
        </motion.div>
      )}

      {/* Transcript Card Grid */}
      {!isLoading && sortedTranscripts.length > 0 && (
        <motion.div
          initial="hidden"
          animate="visible"
          variants={{
            hidden: {},
            visible: { transition: { staggerChildren: 0.05 } },
          }}
          className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
        >
          {sortedTranscripts.map((t) => {
            const colors = statusColors[t.status] || statusColors.pending;
            const isSelected = selectedIds.has(t.id);

            return (
              <motion.div
                key={t.id}
                variants={{
                  hidden: { opacity: 0, y: 20 },
                  visible: {
                    opacity: 1,
                    y: 0,
                    transition: { duration: 0.4, ease: [0.22, 1, 0.36, 1] },
                  },
                }}
                className="group relative p-5 rounded-lg border cursor-pointer transition-colors"
                style={{
                  backgroundColor: 'var(--color-surface)',
                  borderColor: isSelected ? 'var(--color-accent)' : 'var(--color-separator)',
                }}
                onClick={() => navigate(`/?id=${t.id}`)}
              >
                {/* Select checkbox */}
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    toggleSelect(t.id);
                  }}
                  className="absolute top-4 right-4 p-1 rounded-sm transition-opacity duration-200"
                  style={{
                    opacity: isSelected ? 1 : undefined,
                    color: isSelected ? 'var(--color-accent)' : 'var(--color-text-secondary)',
                    minHeight: '32px',
                    minWidth: '32px',
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                  }}
                >
                  {isSelected ? (
                    <CheckSquare className="w-5 h-5" />
                  ) : (
                    <Square className="w-5 h-5 opacity-0 group-hover:opacity-100 transition-opacity duration-200" />
                  )}
                </button>

                {/* Title */}
                <h3
                  className="text-sm font-semibold mb-1.5 pr-8 line-clamp-2 leading-snug"
                  style={{ color: 'var(--color-text)' }}
                >
                  {t.title || 'Untitled Video'}
                </h3>

                {/* Channel */}
                <div className="flex items-center gap-1.5 mb-3">
                  <User className="w-3.5 h-3.5" style={{ color: 'var(--color-text-secondary)' }} />
                  <span className="text-xs truncate" style={{ color: 'var(--color-text-secondary)' }}>
                    {t.channel_name || 'Unknown channel'}
                  </span>
                </div>

                {/* Metadata row */}
                <div className="flex items-center gap-3 flex-wrap">
                  {/* Status badge */}
                  <span
                    className="inline-flex items-center px-2 py-0.5 rounded-sm text-xs font-medium"
                    style={{
                      backgroundColor: colors.bg,
                      color: colors.text,
                      border: `1px solid ${colors.border}`,
                    }}
                  >
                    {t.status}
                  </span>

                  {/* Date */}
                  <span className="flex items-center gap-1 text-xs" style={{ color: 'var(--color-text-secondary)' }}>
                    <Clock className="w-3 h-3" />
                    {formatDate(t.created_at)}
                  </span>

                  {/* Word count */}
                  {t.word_count > 0 && (
                    <span className="flex items-center gap-1 text-xs" style={{ color: 'var(--color-text-secondary)' }}>
                      <FileText className="w-3 h-3" />
                      {t.word_count.toLocaleString()} words
                    </span>
                  )}
                </div>
              </motion.div>
            );
          })}
        </motion.div>
      )}

      {/* Pagination */}
      {!isLoading && totalPages > 1 && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.3 }}
          className="flex items-center justify-center gap-2 mt-8"
        >
          <button
            onClick={() => setPage((p) => Math.max(1, p - 1))}
            disabled={page === 1}
            className="flex items-center gap-1 px-4 py-2.5 rounded-md border text-sm font-medium transition-colors duration-200 disabled:opacity-40"
            style={{
              backgroundColor: 'var(--color-surface)',
              borderColor: 'var(--color-separator)',
              color: 'var(--color-text-secondary)',
              minHeight: '44px',
            }}
          >
            <ChevronLeft className="w-4 h-4" />
            Previous
          </button>
          <span className="text-sm px-4" style={{ color: 'var(--color-text-secondary)' }}>
            Page {page} of {totalPages}
          </span>
          <button
            onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
            disabled={page === totalPages}
            className="flex items-center gap-1 px-4 py-2.5 rounded-md border text-sm font-medium transition-colors duration-200 disabled:opacity-40"
            style={{
              backgroundColor: 'var(--color-surface)',
              borderColor: 'var(--color-separator)',
              color: 'var(--color-text-secondary)',
              minHeight: '44px',
            }}
          >
            Next
            <ChevronRight className="w-4 h-4" />
          </button>
        </motion.div>
      )}
    </motion.div>
  );
}
