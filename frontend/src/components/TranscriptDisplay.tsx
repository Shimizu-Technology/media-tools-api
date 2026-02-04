import { useState, useCallback, useMemo } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Clock,
  FileText,
  Globe,
  User,
  Copy,
  Check,
  Loader2,
  AlertCircle,
  ChevronDown,
  ChevronUp,
  Share2,
  BookOpen,
  Timer,
  Eye,
  EyeOff,
  FileDown,
  Type,
} from 'lucide-react';
import type { Transcript, ExportFormat } from '../lib/api';
import { downloadExport } from '../lib/api';
import { SaveToWorkspace } from './SaveToWorkspace';

interface TranscriptDisplayProps {
  transcript: Transcript;
}

/**
 * Displays a transcript with metadata, copy/download/share, and toggleable features.
 * MTA-12: Enhanced transcript viewer with export, timestamps, and code highlighting.
 *
 * Design rules (Shimizu guide):
 * - NO emoji -- Lucide React icons ONLY
 * - Mobile-first, 44px touch targets
 * - Brand tokens via CSS custom properties
 * - Framer Motion animations on all interactions
 * - Dark mode support
 */
export function TranscriptDisplay({ transcript }: TranscriptDisplayProps) {
  const [copied, setCopied] = useState(false);
  const [linkCopied, setLinkCopied] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [showTimestamps, setShowTimestamps] = useState(false);
  const [downloading, setDownloading] = useState<ExportFormat | null>(null);

  // Calculate reading time (~200 words per minute for average reader)
  const readingTime = useMemo(() => {
    const minutes = Math.ceil(transcript.word_count / 200);
    return minutes <= 1 ? '1 min read' : `${minutes} min read`;
  }, [transcript.word_count]);

  // Process transcript text: detect code blocks and optionally add timestamps
  const processedText = useMemo(() => {
    let text = transcript.transcript_text;
    if (!text) return '';

    // Detect code-like segments (lines starting with common code patterns)
    // and wrap them for styling. This is approximate -- real transcripts
    // may mention code without being actual code blocks.
    text = text.replace(
      /((?:function |const |let |var |import |export |class |def |return |if \(|for \(|while \(|console\.log|print\().*)/g,
      '`$1`'
    );

    return text;
  }, [transcript.transcript_text]);

  // Generate approximate timestamp markers for the transcript
  const timestampedSegments = useMemo(() => {
    if (!transcript.transcript_text || transcript.duration <= 0) return [];

    const words = transcript.transcript_text.split(/\s+/);
    const wordsPerSegment = 50; // ~20 seconds of speech
    const segments: Array<{ time: string; text: string }> = [];
    const secondsPerWord = transcript.duration / words.length;

    for (let i = 0; i < words.length; i += wordsPerSegment) {
      const end = Math.min(i + wordsPerSegment, words.length);
      const timeSec = Math.floor(i * secondsPerWord);
      const h = Math.floor(timeSec / 3600);
      const m = Math.floor((timeSec % 3600) / 60);
      const s = timeSec % 60;
      const timeStr = h > 0
        ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
        : `${m}:${String(s).padStart(2, '0')}`;

      segments.push({
        time: timeStr,
        text: words.slice(i, end).join(' '),
      });
    }

    return segments;
  }, [transcript.transcript_text, transcript.duration]);

  const handleCopy = useCallback(async () => {
    await navigator.clipboard.writeText(transcript.transcript_text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [transcript.transcript_text]);

  const handleShareLink = useCallback(async () => {
    const shareUrl = `${window.location.origin}?transcript=${transcript.id}`;
    await navigator.clipboard.writeText(shareUrl);
    setLinkCopied(true);
    setTimeout(() => setLinkCopied(false), 2000);
  }, [transcript.id]);

  const handleDownload = useCallback(async (format: ExportFormat) => {
    setDownloading(format);
    try {
      const blob = await downloadExport(transcript.id, format);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${transcript.title || transcript.youtube_id}.${format}`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    } catch (err) {
      console.error('Download failed:', err);
    }
    setDownloading(null);
  }, [transcript.id, transcript.title, transcript.youtube_id]);

  const formatDuration = (seconds: number): string => {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    if (h > 0) return `${h}h ${m}m`;
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
  };

  // -- Status-specific rendering --

  if (transcript.status === 'pending' || transcript.status === 'processing') {
    return (
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        className="w-full max-w-3xl mx-auto p-8 rounded-2xl border text-center"
        style={{
          backgroundColor: 'var(--color-surface-elevated)',
          borderColor: 'var(--color-border)',
        }}
      >
        <Loader2 className="w-8 h-8 animate-spin mx-auto mb-4" style={{ color: 'var(--color-brand-500)' }} />
        <p className="text-lg font-medium" style={{ color: 'var(--color-text-primary)' }}>
          Extracting transcript...
        </p>
        <p className="text-sm mt-2" style={{ color: 'var(--color-text-secondary)' }}>
          This usually takes 10-30 seconds
        </p>
      </motion.div>
    );
  }

  if (transcript.status === 'failed') {
    return (
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        className="w-full max-w-3xl mx-auto p-8 rounded-2xl border"
        style={{
          backgroundColor: 'var(--color-surface-elevated)',
          borderColor: '#ef4444',
        }}
      >
        <div className="flex items-center gap-3 mb-3">
          <AlertCircle className="w-6 h-6 text-red-500 shrink-0" />
          <p className="text-lg font-medium" style={{ color: 'var(--color-text-primary)' }}>
            Extraction failed
          </p>
        </div>
        <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
          {transcript.error_message || 'Unable to extract transcript. The video may be private or have no captions available.'}
        </p>
      </motion.div>
    );
  }

  // -- Completed transcript --

  const previewLength = 500;
  const isLong = transcript.transcript_text.length > previewLength;
  const displayText = showTimestamps
    ? null  // timestamps mode uses segments
    : (expanded ? processedText : processedText.slice(0, previewLength));

  return (
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
      className="w-full max-w-3xl mx-auto"
    >
      {/* Video Info Card */}
      <motion.div
        initial={{ opacity: 0, y: 10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.1 }}
        className="p-6 rounded-2xl border mb-4"
        style={{
          backgroundColor: 'var(--color-surface-elevated)',
          borderColor: 'var(--color-border)',
        }}
      >
        <h2
          className="text-xl font-semibold mb-4 tracking-tight"
          style={{ color: 'var(--color-text-primary)' }}
        >
          {transcript.title || 'Untitled Video'}
        </h2>

        {/* Metadata Grid - responsive: 2 cols mobile, 3 cols tablet, 3 cols desktop */}
        <div className="grid grid-cols-2 gap-3 sm:gap-4">
          <MetadataItem
            icon={<User className="w-4 h-4" />}
            label="Channel"
            value={transcript.channel_name || 'Unknown'}
          />
          <MetadataItem
            icon={<Clock className="w-4 h-4" />}
            label="Duration"
            value={formatDuration(transcript.duration)}
          />
          <MetadataItem
            icon={<Type className="w-4 h-4" />}
            label="Words"
            value={transcript.word_count.toLocaleString()}
          />
          <MetadataItem
            icon={<BookOpen className="w-4 h-4" />}
            label="Reading Time"
            value={readingTime}
          />
          <MetadataItem
            icon={<Globe className="w-4 h-4" />}
            label="Language"
            value={transcript.language.toUpperCase()}
          />
          <MetadataItem
            icon={<Timer className="w-4 h-4" />}
            label="Extracted"
            value={new Date(transcript.created_at).toLocaleDateString()}
          />
        </div>
      </motion.div>

      {/* Action Bar - Mobile-first layout */}
      <motion.div
        initial={{ opacity: 0, y: 10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.2 }}
        className="space-y-3 mb-4"
      >
        {/* Primary actions row */}
        <div className="flex flex-wrap items-center gap-2">
          {/* Copy button */}
          <ActionButton
            icon={copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
            label={copied ? 'Copied' : 'Copy'}
            onClick={handleCopy}
            active={copied}
          />

          {/* Share link */}
          <ActionButton
            icon={linkCopied ? <Check className="w-4 h-4" /> : <Share2 className="w-4 h-4" />}
            label={linkCopied ? 'Link Copied' : 'Share'}
            onClick={handleShareLink}
            active={linkCopied}
          />

          {/* Toggle timestamps */}
          {transcript.duration > 0 && (
            <ActionButton
              icon={showTimestamps ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
              label={showTimestamps ? 'Hide Timestamps' : 'Show Timestamps'}
              onClick={() => setShowTimestamps(!showTimestamps)}
              active={showTimestamps}
            />
          )}

          {/* Save to workspace (MTA-20) */}
          <SaveToWorkspace itemType="transcript" itemId={transcript.id} />
        </div>

        {/* Export row - separate line for cleaner mobile layout */}
        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-xs font-medium flex items-center gap-1" style={{ color: 'var(--color-text-muted)' }}>
            <FileDown className="w-3.5 h-3.5" />
            Export:
          </span>
          <div className="flex items-center gap-1.5">
            {(['txt', 'md', 'srt', 'json'] as ExportFormat[]).map((format) => (
              <motion.button
                key={format}
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                onClick={() => handleDownload(format)}
                disabled={downloading === format}
                className="px-3 py-2 rounded-lg text-xs font-medium uppercase transition-colors duration-200 disabled:opacity-50"
                style={{
                  backgroundColor: 'var(--color-surface-overlay)',
                  color: 'var(--color-text-secondary)',
                  border: '1px solid var(--color-border)',
                  minHeight: '36px',
                }}
                title={`Download as ${format.toUpperCase()}`}
              >
                {downloading === format ? (
                  <Loader2 className="w-3 h-3 animate-spin" />
                ) : (
                  format
                )}
              </motion.button>
            ))}
          </div>
        </div>
      </motion.div>

      {/* Transcript Text Card */}
      <motion.div
        initial={{ opacity: 0, y: 10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.3 }}
        className="p-6 rounded-2xl border"
        style={{
          backgroundColor: 'var(--color-surface-elevated)',
          borderColor: 'var(--color-border)',
        }}
      >
        <div className="flex items-center justify-between mb-4">
          <h3
            className="text-base font-semibold flex items-center gap-2"
            style={{ color: 'var(--color-text-primary)' }}
          >
            <FileText className="w-4 h-4" style={{ color: 'var(--color-brand-500)' }} />
            Transcript
          </h3>
          <div className="flex items-center gap-3">
            {/* Expand/Collapse button at top (only when expanded) */}
            {!showTimestamps && isLong && expanded && (
              <button
                onClick={() => setExpanded(false)}
                className="flex items-center gap-1 text-xs font-medium transition-colors"
                style={{ color: 'var(--color-brand-500)', minHeight: '32px' }}
              >
                <ChevronUp className="w-3.5 h-3.5" />
                Collapse
              </button>
            )}
            <span className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
              {transcript.word_count.toLocaleString()} words
            </span>
          </div>
        </div>

        {/* Timestamps mode */}
        <AnimatePresence mode="wait">
          {showTimestamps ? (
            <motion.div
              key="timestamps"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.2 }}
              className="space-y-3"
            >
              {timestampedSegments.map((seg, i) => (
                <motion.div
                  key={i}
                  initial={{ opacity: 0, x: -8 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: i * 0.02, duration: 0.3 }}
                  className="flex gap-3"
                >
                  <span
                    className="shrink-0 text-xs font-mono pt-0.5 w-14 text-right"
                    style={{ color: 'var(--color-brand-500)' }}
                  >
                    {seg.time}
                  </span>
                  <span
                    className="text-sm leading-relaxed"
                    style={{ color: 'var(--color-text-secondary)' }}
                  >
                    {seg.text}
                  </span>
                </motion.div>
              ))}
            </motion.div>
          ) : (
            <motion.div
              key="plaintext"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.2 }}
            >
              <TranscriptText text={displayText || ''} />

              {isLong && !expanded && (
                <span style={{ color: 'var(--color-text-muted)' }}>...</span>
              )}
            </motion.div>
          )}
        </AnimatePresence>

        {/* Expand/Collapse toggle (only in plaintext mode) */}
        {!showTimestamps && isLong && (
          <motion.button
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            onClick={() => setExpanded(!expanded)}
            className="flex items-center gap-1.5 mt-4 text-sm font-medium transition-colors duration-200"
            style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}
          >
            {expanded ? (
              <>
                <ChevronUp className="w-4 h-4" />
                Show less
              </>
            ) : (
              <>
                <ChevronDown className="w-4 h-4" />
                Show full transcript ({transcript.word_count.toLocaleString()} words)
              </>
            )}
          </motion.button>
        )}
      </motion.div>

      {/* Toast notification for copy actions */}
      <AnimatePresence>
        {(copied || linkCopied) && (
          <motion.div
            initial={{ opacity: 0, y: 20, scale: 0.95 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 20, scale: 0.95 }}
            transition={{ duration: 0.2 }}
            className="fixed bottom-6 left-1/2 -translate-x-1/2 z-50 flex items-center gap-2 px-4 py-3 rounded-xl shadow-lg"
            style={{
              backgroundColor: '#10b981',
              color: 'white',
            }}
          >
            <Check className="w-4 h-4" />
            <span className="text-sm font-medium">
              {copied ? 'Transcript copied to clipboard' : 'Share link copied to clipboard'}
            </span>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}

/**
 * Renders transcript text with inline code highlighting.
 * Backtick-wrapped text is rendered in a monospace font with a subtle background.
 */
function TranscriptText({ text }: { text: string }) {
  // Split text into segments: normal text and `code` blocks
  const parts = text.split(/(`[^`]+`)/g);

  return (
    <div
      className="text-sm leading-relaxed whitespace-pre-wrap"
      style={{ color: 'var(--color-text-secondary)' }}
    >
      {parts.map((part, i) => {
        if (part.startsWith('`') && part.endsWith('`')) {
          // Render as inline code
          return (
            <code
              key={i}
              className="px-1.5 py-0.5 rounded text-xs font-mono"
              style={{
                backgroundColor: 'var(--color-surface)',
                color: 'var(--color-brand-500)',
                border: '1px solid var(--color-border)',
              }}
            >
              {part.slice(1, -1)}
            </code>
          );
        }
        return <span key={i}>{part}</span>;
      })}
    </div>
  );
}

/** Action button used in the toolbar (copy, share, timestamps toggle) */
function ActionButton({
  icon,
  label,
  onClick,
  active,
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
  active?: boolean;
}) {
  return (
    <motion.button
      whileHover={{ scale: 1.03 }}
      whileTap={{ scale: 0.97 }}
      onClick={onClick}
      className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium transition-colors duration-200"
      style={{
        backgroundColor: active ? '#10b981' : 'var(--color-surface-overlay)',
        color: active ? 'white' : 'var(--color-text-secondary)',
        border: `1px solid ${active ? '#10b981' : 'var(--color-border)'}`,
        minHeight: '44px', // Touch target
      }}
    >
      {icon}
      <span className="hidden sm:inline">{label}</span>
    </motion.button>
  );
}

/** Small metadata display item */
function MetadataItem({ icon, label, value }: { icon: React.ReactNode; label: string; value: string }) {
  return (
    <div className="flex items-center gap-2">
      <span style={{ color: 'var(--color-text-muted)' }}>{icon}</span>
      <div>
        <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>{label}</p>
        <p className="text-sm font-medium truncate" style={{ color: 'var(--color-text-primary)' }}>{value}</p>
      </div>
    </div>
  );
}
