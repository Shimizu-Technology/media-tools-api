import { useState, useCallback, useRef, useEffect } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import {
  FileText,
  Upload,
  Copy,
  Check,
  Loader2,
  AlertCircle,
  Download,
  BookOpen,
  Type,
  Layers,
  X,
  History,
} from 'lucide-react';
import {
  extractPDF,
  getPDFExtraction,
  type PDFExtraction,
  type APIError,
} from '../lib/api';
import { TranscriptChatPanel } from '../components/TranscriptChatPanel';

/**
 * PDF text extraction page (MTA-17).
 * Drag-and-drop PDF upload with text extraction display.
 *
 * Design rules (Shimizu guide):
 * - NO emoji — Lucide React icons ONLY
 * - Mobile-first, 44px min touch targets
 * - Brand tokens via CSS custom properties
 * - Framer Motion animations
 * - Dark mode support
 */
export function PdfPage() {
  const [searchParams, setSearchParams] = useSearchParams();
  
  const [file, setFile] = useState<File | null>(null);
  const [result, setResult] = useState<PDFExtraction | null>(null);
  const [isProcessing, setIsProcessing] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);
  const [isDragging, setIsDragging] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const maxSizeMB = 50;

  // Load extraction from URL param (when coming from My Library)
  useEffect(() => {
    const id = searchParams.get('id');
    if (id && !result) {
      getPDFExtraction(id)
        .then((t) => setResult(t))
        .catch(() => setError('PDF extraction not found'));
    }
  }, [searchParams, result]);

  const validateFile = (f: File): string | null => {
    const ext = '.' + f.name.split('.').pop()?.toLowerCase();
    if (ext !== '.pdf') {
      return `Unsupported format "${ext}". Only PDF files are accepted.`;
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
      const extraction = await extractPDF(file);
      setResult(extraction);
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'PDF extraction failed. Please try again.');
    }

    setIsProcessing(false);
  };

  const handleCopy = useCallback(async () => {
    if (!result?.text_content) return;
    await navigator.clipboard.writeText(result.text_content);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [result]);

  const handleDownload = useCallback(() => {
    if (!result?.text_content) return;
    const blob = new Blob([result.text_content], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${result.original_name.replace(/\.pdf$/i, '')}_extracted.txt`;
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
    setSearchParams({});
  };

  // Split text by page break markers for display
  const pageSegments = result?.text_content
    ? result.text_content.split(/\n--- Page \d+ ---\n/).filter(Boolean)
    : [];

  return (
    <main className="relative pt-20 sm:pt-28 pb-12 sm:pb-16 px-4 sm:px-6">
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
            <FileText className="w-4 h-4" />
            Pure Go PDF Processing
          </motion.div>

          <motion.h1
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
            className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight mb-4"
            style={{ color: 'var(--color-text-primary)' }}
          >
            PDF{' '}
            <span
              className="bg-clip-text text-transparent"
              style={{
                backgroundImage: 'linear-gradient(135deg, var(--color-brand-400), var(--color-brand-600))',
              }}
            >
              Text Extraction
            </span>
          </motion.h1>

          <motion.p
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.2, ease: [0.22, 1, 0.36, 1] }}
            className="text-lg max-w-xl mx-auto mb-4"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            Upload a PDF to extract all text content.
            Page breaks are preserved for easy navigation.
          </motion.p>

          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.3 }}
          >
            <Link
              to="/library?type=pdf"
              className="inline-flex items-center gap-1.5 text-sm font-medium transition-colors"
              style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}
            >
              <History className="w-4 h-4" />
              View past extractions
            </Link>
          </motion.div>
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
              accept=".pdf"
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
              {isDragging ? 'Drop your PDF here' : 'Drag and drop a PDF, or click to browse'}
            </p>
            <p className="text-sm" style={{ color: 'var(--color-text-muted)' }}>
              PDF files only — Max {maxSizeMB}MB
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
                <FileText className="w-5 h-5 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
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
                  <FileText className="w-5 h-5" />
                  Extract Text
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
            Extracting text from PDF...
          </p>
          <p className="text-sm mt-2" style={{ color: 'var(--color-text-secondary)' }}>
            This usually takes a few seconds
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
            backgroundColor: 'rgba(239, 68, 68, 0.12)',
            border: '1px solid rgba(239, 68, 68, 0.24)',
            color: 'var(--color-error)',
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
            className="max-w-5xl mx-auto"
          >
            {/* Back / New button */}
            <motion.button
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              onClick={handleReset}
              className="flex items-center gap-1.5 text-sm font-medium mb-6 transition-colors"
              style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}
            >
              <FileText className="w-4 h-4" />
              New extraction
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
                <FileText className="w-5 h-5" style={{ color: 'var(--color-brand-500)' }} />
                {result.original_name}
              </h2>

              <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
                <MetaItem icon={<Layers className="w-4 h-4" />} label="Pages" value={result.page_count.toString()} />
                <MetaItem icon={<Type className="w-4 h-4" />} label="Words" value={result.word_count.toLocaleString()} />
                <MetaItem
                  icon={<BookOpen className="w-4 h-4" />}
                  label="Reading Time"
                  value={`${Math.ceil(result.word_count / 200)} min`}
                />
              </div>
            </div>

            {/* Actions */}
            <div className="flex items-center gap-2 mb-4">
              <ActionBtn
                icon={copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
                label={copied ? 'Copied' : 'Copy All'}
                onClick={handleCopy}
                active={copied}
              />
              <ActionBtn
                icon={<Download className="w-4 h-4" />}
                label="Download .txt"
                onClick={handleDownload}
              />
            </div>

            <div className="mt-6 grid gap-6 lg:grid-cols-[1.4fr_0.9fr]">
              <div className="lg:col-span-2 h-px" style={{ backgroundColor: 'var(--color-border)' }} />
              {/* Extracted text with page breaks */}
              <div
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
                    <BookOpen className="w-4 h-4" style={{ color: 'var(--color-brand-500)' }} />
                    Extracted Text
                  </h3>
                  <button
                    onClick={handleCopy}
                    className="flex items-center gap-1 px-2 py-1.5 rounded-lg text-xs font-medium border transition-colors"
                    style={{
                      backgroundColor: copied ? 'var(--color-success)' : 'var(--color-surface-overlay)',
                      color: copied ? 'white' : 'var(--color-text-secondary)',
                      borderColor: copied ? 'var(--color-success)' : 'var(--color-border)',
                      minHeight: '32px',
                    }}
                  >
                    {copied ? <Check className="w-3 h-3" /> : <Copy className="w-3 h-3" />}
                    <span className="hidden sm:inline">{copied ? 'Copied' : 'Copy'}</span>
                  </button>
                </div>

                {pageSegments.length > 1 ? (
                  <div className="space-y-6">
                    {pageSegments.map((pageText, i) => (
                      <motion.div
                        key={i}
                        initial={{ opacity: 0, y: 10 }}
                        animate={{ opacity: 1, y: 0 }}
                        transition={{ delay: i * 0.05, duration: 0.3 }}
                      >
                        {i > 0 && (
                          <div className="flex items-center gap-3 mb-3">
                            <div className="flex-1 h-px" style={{ backgroundColor: 'var(--color-border)' }} />
                            <span
                              className="text-xs font-medium px-2 py-1 rounded-full"
                              style={{
                                backgroundColor: 'var(--color-surface)',
                                color: 'var(--color-text-muted)',
                                border: '1px solid var(--color-border)',
                              }}
                            >
                              Page {i + 1}
                            </span>
                            <div className="flex-1 h-px" style={{ backgroundColor: 'var(--color-border)' }} />
                          </div>
                        )}
                        <div
                          className="text-sm leading-relaxed whitespace-pre-wrap"
                          style={{ color: 'var(--color-text-secondary)' }}
                        >
                          {pageText.trim()}
                        </div>
                      </motion.div>
                    ))}
                  </div>
                ) : (
                  <div
                    className="text-sm leading-relaxed whitespace-pre-wrap"
                    style={{ color: 'var(--color-text-secondary)' }}
                  >
                    {result.text_content}
                  </div>
                )}
              </div>

              {/* AI Chat */}
              <div>
                <TranscriptChatPanel itemType="pdf" itemId={result.id} />
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
            style={{ backgroundColor: 'var(--color-success)', color: 'white' }}
          >
            <Check className="w-4 h-4" />
            <span className="text-sm font-medium">Text copied to clipboard</span>
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
        backgroundColor: active ? 'var(--color-success)' : 'var(--color-surface-overlay)',
        color: active ? 'white' : 'var(--color-text-secondary)',
        border: `1px solid ${active ? 'var(--color-success)' : 'var(--color-border)'}`,
        minHeight: '44px',
      }}
    >
      {icon}
      <span className="hidden sm:inline">{label}</span>
    </motion.button>
  );
}
