import { useState, useCallback } from 'react';
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
} from 'lucide-react';
import type { Transcript } from '../lib/api';

interface TranscriptDisplayProps {
  transcript: Transcript;
}

/**
 * Displays a transcript with metadata and copy functionality.
 * Follows Shimizu design guide: brand tokens, Lucide icons only, mobile-first.
 */
export function TranscriptDisplay({ transcript }: TranscriptDisplayProps) {
  const [copied, setCopied] = useState(false);
  const [expanded, setExpanded] = useState(false);

  const handleCopy = useCallback(async () => {
    await navigator.clipboard.writeText(transcript.transcript_text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [transcript.transcript_text]);

  const formatDuration = (seconds: number): string => {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    if (h > 0) return `${h}h ${m}m`;
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
  };

  // Status-specific rendering
  if (transcript.status === 'pending' || transcript.status === 'processing') {
    return (
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        className="w-full max-w-2xl mx-auto p-8 rounded-2xl border text-center"
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
        className="w-full max-w-2xl mx-auto p-8 rounded-2xl border"
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

  // Completed transcript
  const previewLength = 500;
  const isLong = transcript.transcript_text.length > previewLength;
  const displayText = expanded ? transcript.transcript_text : transcript.transcript_text.slice(0, previewLength);

  return (
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
      className="w-full max-w-2xl mx-auto"
    >
      {/* Video Info Card */}
      <div
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

        {/* Metadata Grid */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
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
            icon={<FileText className="w-4 h-4" />}
            label="Words"
            value={transcript.word_count.toLocaleString()}
          />
          <MetadataItem
            icon={<Globe className="w-4 h-4" />}
            label="Language"
            value={transcript.language.toUpperCase()}
          />
        </div>
      </div>

      {/* Transcript Text Card */}
      <div
        className="p-6 rounded-2xl border"
        style={{
          backgroundColor: 'var(--color-surface-elevated)',
          borderColor: 'var(--color-border)',
        }}
      >
        <div className="flex items-center justify-between mb-4">
          <h3
            className="text-base font-semibold"
            style={{ color: 'var(--color-text-primary)' }}
          >
            Transcript
          </h3>
          <motion.button
            onClick={handleCopy}
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm font-medium transition-colors duration-200"
            style={{
              backgroundColor: copied ? '#10b981' : 'var(--color-surface-overlay)',
              color: copied ? 'white' : 'var(--color-text-secondary)',
              border: `1px solid ${copied ? '#10b981' : 'var(--color-border)'}`,
            }}
          >
            {copied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
            {copied ? 'Copied' : 'Copy'}
          </motion.button>
        </div>

        <div
          className="text-sm leading-relaxed whitespace-pre-wrap"
          style={{ color: 'var(--color-text-secondary)' }}
        >
          {displayText}
          {isLong && !expanded && '...'}
        </div>

        {/* Expand/Collapse toggle */}
        <AnimatePresence>
          {isLong && (
            <motion.button
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              onClick={() => setExpanded(!expanded)}
              className="flex items-center gap-1.5 mt-4 text-sm font-medium transition-colors duration-200"
              style={{ color: 'var(--color-brand-500)' }}
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
        </AnimatePresence>
      </div>
    </motion.div>
  );
}

/** Small metadata display item */
function MetadataItem({ icon, label, value }: { icon: React.ReactNode; label: string; value: string }) {
  return (
    <div className="flex items-center gap-2">
      <span style={{ color: 'var(--color-text-muted)' }}>{icon}</span>
      <div>
        <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>{label}</p>
        <p className="text-sm font-medium" style={{ color: 'var(--color-text-primary)' }}>{value}</p>
      </div>
    </div>
  );
}
