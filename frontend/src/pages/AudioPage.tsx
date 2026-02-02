import { useState, useCallback, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Mic,
  Upload,
  FileAudio,
  Copy,
  Check,
  Loader2,
  AlertCircle,
  Download,
  Clock,
  Globe,
  Type,
  X,
} from 'lucide-react';
import {
  transcribeAudio,
  type AudioTranscription,
  type APIError,
} from '../lib/api';

/**
 * Audio transcription page (MTA-16).
 * Drag-and-drop audio file upload with Whisper API transcription.
 *
 * Design rules (Shimizu guide):
 * - NO emoji — Lucide React icons ONLY
 * - Mobile-first, 44px min touch targets
 * - Brand tokens via CSS custom properties
 * - Framer Motion animations
 * - Dark mode support
 */
export function AudioPage() {
  const [file, setFile] = useState<File | null>(null);
  const [result, setResult] = useState<AudioTranscription | null>(null);
  const [isProcessing, setIsProcessing] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);
  const [isDragging, setIsDragging] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const allowedExtensions = ['.mp3', '.wav', '.m4a', '.ogg', '.flac', '.webm'];
  const maxSizeMB = 25;

  const validateFile = (f: File): string | null => {
    const ext = '.' + f.name.split('.').pop()?.toLowerCase();
    if (!allowedExtensions.includes(ext)) {
      return `Unsupported format "${ext}". Supported: ${allowedExtensions.join(', ')}`;
    }
    if (f.size > maxSizeMB * 1024 * 1024) {
      return `File too large (${(f.size / 1024 / 1024).toFixed(1)}MB). Max: ${maxSizeMB}MB`;
    }
    return null;
  };

  const handleFile = useCallback((f: File) => {
    const validationError = validateFile(f);
    if (validationError) {
      setError(validationError);
      return;
    }
    setFile(f);
    setError('');
    setResult(null);
  }, []);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
    const droppedFile = e.dataTransfer.files[0];
    if (droppedFile) handleFile(droppedFile);
  }, [handleFile]);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(true);
  }, []);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
  }, []);

  const handleSubmit = async () => {
    if (!file) return;

    setIsProcessing(true);
    setError('');

    try {
      const transcription = await transcribeAudio(file);
      setResult(transcription);
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Transcription failed. Please try again.');
    }

    setIsProcessing(false);
  };

  const handleCopy = useCallback(async () => {
    if (!result?.transcript_text) return;
    await navigator.clipboard.writeText(result.transcript_text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [result]);

  const handleDownload = useCallback(() => {
    if (!result?.transcript_text) return;
    const blob = new Blob([result.transcript_text], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${result.original_name.replace(/\.[^.]+$/, '')}_transcript.txt`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }, [result]);

  const handleReset = () => {
    setFile(null);
    setResult(null);
    setError('');
    setCopied(false);
  };

  const formatDuration = (seconds: number): string => {
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
  };

  return (
    <main className="relative pt-28 pb-16 px-6">
      {/* Hero */}
      {!result && (
        <div className="text-center mb-12">
          <motion.div
            initial={{ opacity: 0, scale: 0.9 }}
            animate={{ opacity: 1, scale: 1 }}
            transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
            className="inline-flex items-center gap-2 px-4 py-1.5 rounded-full text-sm font-medium mb-6"
            style={{
              backgroundColor: 'var(--color-brand-50)',
              color: 'var(--color-brand-500)',
            }}
          >
            <Mic className="w-4 h-4" />
            Powered by OpenAI Whisper
          </motion.div>

          <motion.h1
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
            className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight mb-4"
            style={{ color: 'var(--color-text-primary)' }}
          >
            Audio{' '}
            <span
              className="bg-clip-text text-transparent"
              style={{
                backgroundImage: 'linear-gradient(135deg, var(--color-brand-400), var(--color-brand-600))',
              }}
            >
              Transcription
            </span>
          </motion.h1>

          <motion.p
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.2, ease: [0.22, 1, 0.36, 1] }}
            className="text-lg max-w-xl mx-auto"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            Upload an audio file to get an accurate transcription.
            Supports MP3, WAV, M4A, OGG, FLAC, and WebM.
          </motion.p>
        </div>
      )}

      {/* Upload Zone */}
      {!result && !isProcessing && (
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
          className="max-w-2xl mx-auto"
        >
          <div
            onDrop={handleDrop}
            onDragOver={handleDragOver}
            onDragLeave={handleDragLeave}
            onClick={() => inputRef.current?.click()}
            className="relative cursor-pointer rounded-2xl border-2 border-dashed p-12 text-center transition-all duration-300"
            style={{
              borderColor: isDragging ? 'var(--color-brand-500)' : 'var(--color-border)',
              backgroundColor: isDragging ? 'var(--color-brand-50)' : 'var(--color-surface-elevated)',
            }}
          >
            <input
              ref={inputRef}
              type="file"
              accept={allowedExtensions.join(',')}
              onChange={(e) => {
                const f = e.target.files?.[0];
                if (f) handleFile(f);
              }}
              className="hidden"
            />

            <motion.div
              animate={{ scale: isDragging ? 1.1 : 1 }}
              transition={{ type: 'spring', stiffness: 300, damping: 20 }}
            >
              <Upload
                className="w-12 h-12 mx-auto mb-4"
                style={{ color: isDragging ? 'var(--color-brand-500)' : 'var(--color-text-muted)' }}
              />
            </motion.div>

            <p className="text-base font-medium mb-2" style={{ color: 'var(--color-text-primary)' }}>
              {isDragging ? 'Drop your audio file here' : 'Drag and drop an audio file, or click to browse'}
            </p>
            <p className="text-sm" style={{ color: 'var(--color-text-muted)' }}>
              MP3, WAV, M4A, OGG, FLAC, WebM — Max {maxSizeMB}MB
            </p>
          </div>

          {/* Selected file preview */}
          <AnimatePresence>
            {file && (
              <motion.div
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -10 }}
                className="mt-4 p-4 rounded-xl border flex items-center gap-3"
                style={{
                  backgroundColor: 'var(--color-surface-elevated)',
                  borderColor: 'var(--color-border)',
                }}
              >
                <FileAudio className="w-5 h-5 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium truncate" style={{ color: 'var(--color-text-primary)' }}>
                    {file.name}
                  </p>
                  <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
                    {(file.size / 1024 / 1024).toFixed(2)} MB
                  </p>
                </div>
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    setFile(null);
                  }}
                  className="p-1.5 rounded-lg transition-colors hover:opacity-70"
                  style={{ color: 'var(--color-text-muted)' }}
                >
                  <X className="w-4 h-4" />
                </button>
              </motion.div>
            )}
          </AnimatePresence>

          {/* Submit button */}
          {file && (
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              className="mt-6 text-center"
            >
              <motion.button
                whileHover={{ scale: 1.02 }}
                whileTap={{ scale: 0.98 }}
                onClick={handleSubmit}
                className="px-8 py-3 rounded-xl text-white font-medium text-base transition-colors duration-200"
                style={{
                  backgroundColor: 'var(--color-brand-500)',
                  minHeight: '48px',
                }}
              >
                <span className="flex items-center gap-2">
                  <Mic className="w-5 h-5" />
                  Transcribe Audio
                </span>
              </motion.button>
            </motion.div>
          )}
        </motion.div>
      )}

      {/* Processing state */}
      {isProcessing && (
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="max-w-2xl mx-auto p-8 rounded-2xl border text-center"
          style={{
            backgroundColor: 'var(--color-surface-elevated)',
            borderColor: 'var(--color-border)',
          }}
        >
          <Loader2 className="w-8 h-8 animate-spin mx-auto mb-4" style={{ color: 'var(--color-brand-500)' }} />
          <p className="text-lg font-medium" style={{ color: 'var(--color-text-primary)' }}>
            Transcribing audio...
          </p>
          <p className="text-sm mt-2" style={{ color: 'var(--color-text-secondary)' }}>
            This may take a minute for longer files
          </p>
        </motion.div>
      )}

      {/* Error */}
      {error && (
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          className="max-w-2xl mx-auto mt-6 p-4 rounded-xl text-sm flex items-center gap-3"
          style={{
            backgroundColor: 'rgba(239, 68, 68, 0.1)',
            border: '1px solid rgba(239, 68, 68, 0.2)',
            color: '#ef4444',
          }}
        >
          <AlertCircle className="w-5 h-5 shrink-0" />
          {error}
        </motion.div>
      )}

      {/* Result */}
      <AnimatePresence>
        {result && result.status === 'completed' && (
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
            className="max-w-3xl mx-auto"
          >
            {/* Back / New button */}
            <motion.button
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              onClick={handleReset}
              className="flex items-center gap-1.5 text-sm font-medium mb-6 transition-colors"
              style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}
            >
              <Mic className="w-4 h-4" />
              New transcription
            </motion.button>

            {/* Metadata card */}
            <div
              className="p-6 rounded-2xl border mb-4"
              style={{
                backgroundColor: 'var(--color-surface-elevated)',
                borderColor: 'var(--color-border)',
              }}
            >
              <h2
                className="text-xl font-semibold mb-4 tracking-tight flex items-center gap-2"
                style={{ color: 'var(--color-text-primary)' }}
              >
                <FileAudio className="w-5 h-5" style={{ color: 'var(--color-brand-500)' }} />
                {result.original_name}
              </h2>

              <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
                <MetaItem icon={<Clock className="w-4 h-4" />} label="Duration" value={formatDuration(result.duration)} />
                <MetaItem icon={<Type className="w-4 h-4" />} label="Words" value={result.word_count.toLocaleString()} />
                <MetaItem icon={<Globe className="w-4 h-4" />} label="Language" value={result.language?.toUpperCase() || 'Unknown'} />
                <MetaItem
                  icon={<Clock className="w-4 h-4" />}
                  label="Processed"
                  value={new Date(result.created_at).toLocaleDateString()}
                />
              </div>
            </div>

            {/* Actions */}
            <div className="flex items-center gap-2 mb-4">
              <ActionBtn
                icon={copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
                label={copied ? 'Copied' : 'Copy'}
                onClick={handleCopy}
                active={copied}
              />
              <ActionBtn
                icon={<Download className="w-4 h-4" />}
                label="Download .txt"
                onClick={handleDownload}
              />
            </div>

            {/* Transcript text */}
            <div
              className="p-6 rounded-2xl border"
              style={{
                backgroundColor: 'var(--color-surface-elevated)',
                borderColor: 'var(--color-border)',
              }}
            >
              <h3
                className="text-base font-semibold flex items-center gap-2 mb-4"
                style={{ color: 'var(--color-text-primary)' }}
              >
                <Mic className="w-4 h-4" style={{ color: 'var(--color-brand-500)' }} />
                Transcription
              </h3>
              <div
                className="text-sm leading-relaxed whitespace-pre-wrap"
                style={{ color: 'var(--color-text-secondary)' }}
              >
                {result.transcript_text}
              </div>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Copy toast */}
      <AnimatePresence>
        {copied && (
          <motion.div
            initial={{ opacity: 0, y: 20, scale: 0.95 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 20, scale: 0.95 }}
            transition={{ duration: 0.2 }}
            className="fixed bottom-6 left-1/2 -translate-x-1/2 z-50 flex items-center gap-2 px-4 py-3 rounded-xl shadow-lg"
            style={{ backgroundColor: '#10b981', color: 'white' }}
          >
            <Check className="w-4 h-4" />
            <span className="text-sm font-medium">Transcription copied to clipboard</span>
          </motion.div>
        )}
      </AnimatePresence>
    </main>
  );
}

function MetaItem({ icon, label, value }: { icon: React.ReactNode; label: string; value: string }) {
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

function ActionBtn({
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
        minHeight: '44px',
      }}
    >
      {icon}
      <span className="hidden sm:inline">{label}</span>
    </motion.button>
  );
}
