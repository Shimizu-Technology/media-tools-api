import { useState, useEffect, useCallback, useMemo } from 'react';
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
} from 'lucide-react';
import {
  listTranscripts,
  listAudioTranscriptions,
  listPDFExtractions,
  deleteTranscript,
  deleteAudioTranscription,
  deletePDFExtraction,
  type Transcript,
  type PaginatedResponse,
} from '../lib/api';

type ContentType = 'all' | 'youtube' | 'audio' | 'pdf';

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
}

/**
 * Unified library page showing all content types.
 * Replaces the old YouTube-only HistoryPage.
 */
export function MyLibraryPage() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  
  // Get initial tab from URL or default to 'all'
  const initialTab = (searchParams.get('type') as ContentType) || 'all';
  
  const [activeTab, setActiveTab] = useState<ContentType>(initialTab);
  const [items, setItems] = useState<UnifiedItem[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState('');
  const [searchQuery, setSearchQuery] = useState('');
  const [searchInput, setSearchInput] = useState('');
  const [sortDir, setSortDir] = useState<'desc' | 'asc'>('desc');
  
  // Pagination for YouTube (only type that supports it server-side)
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const perPage = 20;

  // Selection state for bulk delete
  const [selectedItems, setSelectedItems] = useState<Set<string>>(new Set());
  const [isDeleting, setIsDeleting] = useState(false);

  // Update URL when tab changes
  const handleTabChange = (tab: ContentType) => {
    setActiveTab(tab);
    setPage(1);
    setSearchParams(tab === 'all' ? {} : { type: tab });
  };

  // Fetch all content
  const fetchContent = useCallback(async () => {
    setIsLoading(true);
    setError('');
    
    try {
      const unified: UnifiedItem[] = [];
      
      // Fetch based on active tab
      if (activeTab === 'all' || activeTab === 'youtube') {
        const ytResult: PaginatedResponse<Transcript> = await listTranscripts({
          page: activeTab === 'youtube' ? page : 1,
          per_page: activeTab === 'youtube' ? perPage : 50,
          search: searchQuery || undefined,
        });
        
        if (activeTab === 'youtube') {
          setTotalPages(ytResult.total_pages);
        }
        
        ytResult.data.forEach((t) => {
          unified.push({
            id: t.id,
            type: 'youtube',
            title: t.title || 'Untitled Video',
            subtitle: t.channel_name || 'Unknown channel',
            wordCount: t.word_count,
            status: t.status,
            hasSummary: false, // YouTube summaries are separate
            createdAt: t.created_at,
            duration: t.duration,
          });
        });
      }
      
      if (activeTab === 'all' || activeTab === 'audio') {
        const audioResult = await listAudioTranscriptions();
        audioResult.forEach((a) => {
          unified.push({
            id: a.id,
            type: 'audio',
            title: a.original_name,
            subtitle: a.language ? `${a.language.toUpperCase()} • ${formatDuration(a.duration)}` : formatDuration(a.duration),
            wordCount: a.word_count,
            status: a.status,
            hasSummary: a.summary_status === 'completed',
            createdAt: a.created_at,
            duration: a.duration,
          });
        });
      }
      
      if (activeTab === 'all' || activeTab === 'pdf') {
        const pdfResult = await listPDFExtractions();
        pdfResult.forEach((p) => {
          unified.push({
            id: p.id,
            type: 'pdf',
            title: p.original_name,
            subtitle: `${p.page_count} page${p.page_count !== 1 ? 's' : ''}`,
            wordCount: p.word_count,
            status: p.status,
            hasSummary: false,
            createdAt: p.created_at,
            pageCount: p.page_count,
          });
        });
      }
      
      setItems(unified);
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to load content');
      setItems([]);
    }
    
    setIsLoading(false);
  }, [activeTab, page, searchQuery]);

  useEffect(() => {
    fetchContent();
  }, [fetchContent]);

  // Debounced search
  useEffect(() => {
    const timer = setTimeout(() => {
      setSearchQuery(searchInput);
      setPage(1);
    }, 400);
    return () => clearTimeout(timer);
  }, [searchInput]);

  // Client-side filtering and sorting
  const filteredItems = useMemo(() => {
    let result = [...items];
    
    // Filter by search (client-side for audio/pdf, server-side for youtube)
    if (searchInput && activeTab !== 'youtube') {
      const q = searchInput.toLowerCase();
      result = result.filter(
        (item) =>
          item.title.toLowerCase().includes(q) ||
          item.subtitle.toLowerCase().includes(q)
      );
    }
    
    // Sort by date
    result.sort((a, b) => {
      const cmp = new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime();
      return sortDir === 'desc' ? -cmp : cmp;
    });
    
    return result;
  }, [items, searchInput, activeTab, sortDir]);

  const handleItemClick = (item: UnifiedItem) => {
    // Don't navigate if in selection mode
    if (selectedItems.size > 0) {
      toggleSelection(item);
      return;
    }
    switch (item.type) {
      case 'youtube':
        navigate(`/?id=${item.id}`);
        break;
      case 'audio':
        navigate(`/audio?id=${item.id}`);
        break;
      case 'pdf':
        navigate(`/pdf?id=${item.id}`);
        break;
    }
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
      // Remove from local state
      setItems((prev) => prev.filter((i) => !(i.type === item.type && i.id === item.id)));
    } catch (err) {
      setError('Failed to delete item');
    }
    setIsDeleting(false);
  };

  const handleBulkDelete = async () => {
    if (!confirm(`Delete ${selectedItems.size} item(s)?`)) return;
    
    setIsDeleting(true);
    const toDelete = Array.from(selectedItems);
    
    for (const key of toDelete) {
      const [type, id] = key.split('-');
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
      }
    }
    
    // Remove deleted items from local state
    setItems((prev) => prev.filter((item) => !selectedItems.has(`${item.type}-${item.id}`)));
    setSelectedItems(new Set());
    setIsDeleting(false);
  };

  const clearSelection = () => {
    setSelectedItems(new Set());
  };

  const formatDate = (dateStr: string): string => {
    return new Date(dateStr).toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    });
  };

  const tabs: { value: ContentType; label: string; icon: React.ReactNode }[] = [
    { value: 'all', label: 'All', icon: <Library className="w-4 h-4" /> },
    { value: 'youtube', label: 'YouTube', icon: <Youtube className="w-4 h-4" /> },
    { value: 'audio', label: 'Audio', icon: <Mic className="w-4 h-4" /> },
    { value: 'pdf', label: 'PDF', icon: <FileType2 className="w-4 h-4" /> },
  ];

  const statusColors: Record<string, { bg: string; text: string }> = {
    completed: { bg: 'rgba(16, 185, 129, 0.1)', text: '#10b981' },
    processing: { bg: 'rgba(59, 130, 246, 0.1)', text: '#3b82f6' },
    pending: { bg: 'rgba(245, 158, 11, 0.1)', text: '#f59e0b' },
    failed: { bg: 'rgba(239, 68, 68, 0.1)', text: '#ef4444' },
  };

  const typeIcons: Record<string, React.ReactNode> = {
    youtube: <Youtube className="w-4 h-4" />,
    audio: <Mic className="w-4 h-4" />,
    pdf: <FileType2 className="w-4 h-4" />,
  };

  const typeColors: Record<string, string> = {
    youtube: '#ef4444',
    audio: '#3b82f6',
    pdf: '#f59e0b',
  };

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="max-w-6xl mx-auto px-4 sm:px-6 pt-8 sm:pt-12 pb-16"
    >
      {/* Header */}
      <div className="mb-8">
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="text-3xl sm:text-4xl font-bold tracking-tight mb-2"
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
          All your transcripts, recordings, and documents in one place
        </motion.p>
      </div>

      {/* Selection Bar - shown when items are selected */}
      {selectedItems.size > 0 && (
        <motion.div
          initial={{ opacity: 0, y: -10 }}
          animate={{ opacity: 1, y: 0 }}
          className="flex items-center justify-between gap-4 p-4 rounded-xl mb-6"
          style={{ backgroundColor: 'rgba(239, 68, 68, 0.1)', border: '1px solid rgba(239, 68, 68, 0.2)' }}
        >
          <div className="flex items-center gap-3">
            <span className="text-sm font-medium" style={{ color: '#ef4444' }}>
              {selectedItems.size} selected
            </span>
            <button
              onClick={clearSelection}
              className="text-sm transition-colors"
              style={{ color: 'var(--color-text-muted)' }}
            >
              Clear
            </button>
          </div>
          <button
            onClick={handleBulkDelete}
            disabled={isDeleting}
            className="flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium text-white transition-colors disabled:opacity-50"
            style={{ backgroundColor: '#ef4444', minHeight: '44px' }}
          >
            {isDeleting ? <Loader2 className="w-4 h-4 animate-spin" /> : <Trash2 className="w-4 h-4" />}
            Delete Selected
          </button>
        </motion.div>
      )}

      {/* Tabs */}
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.15 }}
        className="flex gap-1 p-1 rounded-xl mb-6 overflow-x-auto"
        style={{ backgroundColor: 'var(--color-surface-elevated)' }}
      >
        {tabs.map((tab) => (
          <button
            key={tab.value}
            onClick={() => handleTabChange(tab.value)}
            className="flex items-center gap-2 px-4 py-2.5 rounded-lg text-sm font-medium transition-all whitespace-nowrap"
            style={{
              backgroundColor: activeTab === tab.value ? 'var(--color-surface)' : 'transparent',
              color: activeTab === tab.value ? 'var(--color-text-primary)' : 'var(--color-text-muted)',
              boxShadow: activeTab === tab.value ? '0 1px 3px rgba(0,0,0,0.1)' : 'none',
              minHeight: '44px',
            }}
          >
            {tab.icon}
            {tab.label}
            {activeTab === tab.value && !isLoading && (
              <span
                className="px-1.5 py-0.5 rounded text-xs"
                style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}
              >
                {filteredItems.length}
              </span>
            )}
          </button>
        ))}
      </motion.div>

      {/* Search + Sort */}
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.2 }}
        className="flex flex-col sm:flex-row gap-3 mb-6"
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
            placeholder="Search by title..."
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
              className="absolute right-3 top-1/2 -translate-y-1/2 p-1"
              style={{ color: 'var(--color-text-muted)' }}
            >
              <X className="w-4 h-4" />
            </button>
          )}
        </div>

        <button
          onClick={() => setSortDir(sortDir === 'desc' ? 'asc' : 'desc')}
          className="flex items-center justify-center gap-2 px-4 py-3 rounded-xl border text-sm font-medium transition-colors"
          style={{
            backgroundColor: 'var(--color-surface-elevated)',
            borderColor: 'var(--color-border)',
            color: 'var(--color-text-secondary)',
            minHeight: '44px',
          }}
        >
          <ArrowUpDown className="w-4 h-4" />
          {sortDir === 'desc' ? 'Newest first' : 'Oldest first'}
        </button>
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
          className="flex items-center gap-3 p-6 rounded-2xl border"
          style={{
            backgroundColor: 'rgba(239, 68, 68, 0.05)',
            borderColor: 'rgba(239, 68, 68, 0.2)',
          }}
        >
          <AlertCircle className="w-5 h-5 text-red-500 shrink-0" />
          <p className="text-sm text-red-500">{error}</p>
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
            {searchInput ? 'No results found' : 'Nothing here yet'}
          </h3>
          <p className="text-sm mb-6" style={{ color: 'var(--color-text-secondary)' }}>
            {searchInput
              ? 'Try adjusting your search'
              : activeTab === 'youtube'
              ? 'Extract a YouTube transcript to see it here'
              : activeTab === 'audio'
              ? 'Upload or record audio to see it here'
              : activeTab === 'pdf'
              ? 'Upload a PDF to see it here'
              : 'Start by extracting a transcript, recording audio, or uploading a PDF'}
          </p>
          {!searchInput && (
            <button
              onClick={() => navigate(activeTab === 'audio' ? '/audio' : activeTab === 'pdf' ? '/pdf' : '/')}
              className="inline-flex items-center gap-2 px-6 py-3 rounded-xl text-white font-medium text-sm"
              style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '44px' }}
            >
              {activeTab === 'audio' ? <Mic className="w-4 h-4" /> : activeTab === 'pdf' ? <FileType2 className="w-4 h-4" /> : <Youtube className="w-4 h-4" />}
              {activeTab === 'audio' ? 'Record or upload audio' : activeTab === 'pdf' ? 'Upload a PDF' : 'Extract a transcript'}
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
                className="group relative p-5 rounded-2xl border cursor-pointer transition-all duration-200 hover:scale-[1.01]"
                style={{
                  backgroundColor: isSelected ? 'rgba(59, 130, 246, 0.05)' : 'var(--color-surface-elevated)',
                  borderColor: isSelected ? 'var(--color-brand-500)' : 'var(--color-border)',
                }}
              >
                {/* Selection checkbox - shown on hover or when items are selected */}
                <button
                  onClick={(e) => { e.stopPropagation(); toggleSelection(item); }}
                  className={`absolute top-4 left-4 p-1 rounded-md transition-opacity ${selectedItems.size > 0 ? 'opacity-100' : 'opacity-0 group-hover:opacity-100'}`}
                  style={{ color: isSelected ? 'var(--color-brand-500)' : 'var(--color-text-muted)' }}
                >
                  {isSelected ? <CheckCircle2 className="w-5 h-5" /> : <Circle className="w-5 h-5" />}
                </button>

                {/* Type indicator + Delete button */}
                <div className="absolute top-4 right-4 flex items-center gap-1">
                  {/* Delete button - shown on hover */}
                  <button
                    onClick={(e) => handleDelete(item, e)}
                    className="p-1.5 rounded-lg opacity-0 group-hover:opacity-100 transition-opacity"
                    style={{ color: 'var(--color-text-muted)' }}
                    title="Delete"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                  <div
                    className="p-1.5 rounded-lg"
                    style={{ backgroundColor: `${typeColors[item.type]}15`, color: typeColors[item.type] }}
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
                      style={{ backgroundColor: 'rgba(168, 85, 247, 0.1)', color: '#a855f7' }}
                    >
                      <Sparkles className="w-3 h-3" />
                      Summarized
                    </span>
                  )}

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

      {/* Pagination (only for YouTube when filtered) */}
      {!isLoading && activeTab === 'youtube' && totalPages > 1 && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className="flex items-center justify-center gap-2 mt-8"
        >
          <button
            onClick={() => setPage((p) => Math.max(1, p - 1))}
            disabled={page === 1}
            className="flex items-center gap-1 px-4 py-2.5 rounded-xl border text-sm font-medium disabled:opacity-40"
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
          <span className="text-sm px-4" style={{ color: 'var(--color-text-muted)' }}>
            Page {page} of {totalPages}
          </span>
          <button
            onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
            disabled={page === totalPages}
            className="flex items-center gap-1 px-4 py-2.5 rounded-xl border text-sm font-medium disabled:opacity-40"
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
