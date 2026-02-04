import { useState, useCallback, useRef, useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
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
  Sparkles,
  Phone,
  Users,
  MessageSquare,
  GraduationCap,
  FileText,
  ChevronDown,
  ListChecks,
  Lightbulb,
  CheckCircle2,
  Square,
  History,
} from 'lucide-react';
import {
  transcribeAudio,
  getAudioTranscription,
  summarizeAudio,
  downloadAudioExport,
  listAudioTranscriptions,
  type AudioTranscription,
  type AudioContentType,
  type APIError,
} from '../lib/api';
import { usePolling } from '../hooks/usePolling';

/**
 * Audio transcription page (MTA-16, MTA-22, MTA-23, MTA-24, MTA-25, MTA-26).
 *
 * Features:
 * - Drag-and-drop file upload OR in-app recording (MediaRecorder)
 * - Whisper API transcription
 * - AI-powered summarization with content-type-aware prompts
 * - Multiple export formats (txt, md, json)
 * - Transcription history with search
 *
 * Design: NO emoji — Lucide icons only. Mobile-first, 44px touch targets.
 */

// Content type options for the selector (MTA-24)
const CONTENT_TYPES: { value: AudioContentType; label: string; icon: React.ReactNode; desc: string }[] = [
  { value: 'general', label: 'General', icon: <FileAudio className="w-4 h-4" />, desc: 'Auto-detect content type' },
  { value: 'phone_call', label: 'Phone Call', icon: <Phone className="w-4 h-4" />, desc: 'Conversations, follow-ups, commitments' },
  { value: 'meeting', label: 'Meeting', icon: <Users className="w-4 h-4" />, desc: 'Agenda, decisions, action items' },
  { value: 'voice_memo', label: 'Voice Memo', icon: <MessageSquare className="w-4 h-4" />, desc: 'Quick thoughts, ideas, reminders' },
  { value: 'interview', label: 'Interview', icon: <FileText className="w-4 h-4" />, desc: 'Q&A, insights, highlights' },
  { value: 'lecture', label: 'Lecture', icon: <GraduationCap className="w-4 h-4" />, desc: 'Key concepts, definitions, takeaways' },
];

export function AudioPage() {
  const [searchParams, setSearchParams] = useSearchParams();
  
  // Upload state
  const [file, setFile] = useState<File | null>(null);
  const [result, setResult] = useState<AudioTranscription | null>(null);
  const [isProcessing, setIsProcessing] = useState(false);
  const [isSummarizing, setIsSummarizing] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState<string>('');
  const [isDragging, setIsDragging] = useState(false);
  const [contentType, setContentType] = useState<AudioContentType>('general');
  const [showTypeDropdown, setShowTypeDropdown] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  // Recording state (MTA-23)
  const [isRecording, setIsRecording] = useState(false);
  const [recordingTime, setRecordingTime] = useState(0);
  const [recordedBlob, setRecordedBlob] = useState<Blob | null>(null);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const streamRef = useRef<MediaStream | null>(null);

  // History state (MTA-25)
  const [showHistory, setShowHistory] = useState(false);
  const [historyItems, setHistoryItems] = useState<AudioTranscription[]>([]);
  const [historyLoading, setHistoryLoading] = useState(false);

  // Export state (MTA-26)
  const [showExportMenu, setShowExportMenu] = useState(false);

  // Tab state: 'upload' | 'record'
  const [activeTab, setActiveTab] = useState<'upload' | 'record'>('upload');

  const allowedExtensions = ['.mp3', '.wav', '.m4a', '.ogg', '.flac', '.webm'];
  const maxSizeMB = 25;

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
      if (streamRef.current) streamRef.current.getTracks().forEach(t => t.stop());
    };
  }, []);

  // Load transcription from URL param (when coming from My Library)
  useEffect(() => {
    const id = searchParams.get('id');
    if (id && !result) {
      getAudioTranscription(id)
        .then((t) => setResult(t))
        .catch(() => setError('Transcription not found'));
    }
  }, [searchParams, result]);

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
    setRecordedBlob(null);
  }, []);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
    const droppedFile = e.dataTransfer.files[0];
    if (droppedFile) handleFile(droppedFile);
  }, [handleFile]);

  // ── Recording (MTA-23) ──

  const startRecording = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;

      const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
        ? 'audio/webm;codecs=opus'
        : 'audio/webm';

      const recorder = new MediaRecorder(stream, { mimeType });
      mediaRecorderRef.current = recorder;
      chunksRef.current = [];

      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };

      recorder.onstop = () => {
        const blob = new Blob(chunksRef.current, { type: mimeType });
        setRecordedBlob(blob);
        stream.getTracks().forEach(t => t.stop());
        streamRef.current = null;
      };

      recorder.start(1000); // Collect data every second
      setIsRecording(true);
      setRecordingTime(0);
      setError('');

      timerRef.current = setInterval(() => {
        setRecordingTime(prev => prev + 1);
      }, 1000);
    } catch (err) {
      setError('Microphone access denied. Please allow microphone access and try again.');
    }
  };

  const stopRecording = () => {
    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== 'inactive') {
      mediaRecorderRef.current.stop();
    }
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
    setIsRecording(false);
  };

  // ── Polling for async transcription completion ──

  const shouldPoll = result?.status === 'pending' || result?.status === 'processing';

  usePolling(
    useCallback(async () => {
      if (!result?.id) throw new Error('No result');
      const updated = await getAudioTranscription(result.id);
      setResult(updated);
      // Update processing state based on status
      if (updated.status === 'completed' || updated.status === 'failed') {
        setIsProcessing(false);
        if (updated.status === 'failed' && updated.error_message) {
          setError(updated.error_message);
        }
      }
      return updated;
    }, [result?.id]),
    {
      enabled: shouldPoll,
      interval: 2000,
      shouldStop: (data: AudioTranscription) => data.status === 'completed' || data.status === 'failed',
    }
  );

  // ── Submit (upload or recording) ──

  const handleSubmit = async () => {
    let uploadFile: File;

    if (activeTab === 'record' && recordedBlob) {
      const timestamp = new Date().toISOString().slice(0, 19).replace(/[T:]/g, '-');
      uploadFile = new File([recordedBlob], `recording-${timestamp}.webm`, { type: recordedBlob.type });
    } else if (file) {
      uploadFile = file;
    } else {
      return;
    }

    setIsProcessing(true);
    setError('');

    try {
      // This now returns immediately with status "pending"
      // The usePolling hook will poll for completion
      const transcription = await transcribeAudio(uploadFile);
      setResult(transcription);
      // Don't set isProcessing to false here - polling will do that
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Transcription failed. Please try again.');
      setIsProcessing(false);
    }
  };

  // ── Summarize (MTA-22) ──

  const handleSummarize = async () => {
    if (!result) return;
    setIsSummarizing(true);
    setError('');

    try {
      const updated = await summarizeAudio(result.id, { content_type: contentType });
      setResult(updated);
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Summarization failed.');
    }

    setIsSummarizing(false);
  };

  // ── Copy helpers ──

  const handleCopy = useCallback(async (text: string, label: string) => {
    await navigator.clipboard.writeText(text);
    setCopied(label);
    setTimeout(() => setCopied(''), 2000);
  }, []);

  // ── Export (MTA-26) ──

  const handleExport = async (format: 'txt' | 'md' | 'json') => {
    if (!result) return;
    setShowExportMenu(false);
    try {
      const blob = await downloadAudioExport(result.id, format);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      const baseName = result.original_name.replace(/\.[^.]+$/, '');
      a.download = `${baseName}_${format === 'md' ? 'summary' : format === 'txt' ? 'transcript' : 'data'}.${format}`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    } catch {
      setError(`Export failed. Please try again.`);
    }
  };

  // ── History (MTA-25) ──

  const loadHistory = async () => {
    setHistoryLoading(true);
    try {
      const items = await listAudioTranscriptions();
      setHistoryItems(items);
    } catch {
      setError('Failed to load history.');
    }
    setHistoryLoading(false);
  };

  const toggleHistory = () => {
    if (!showHistory) loadHistory();
    setShowHistory(!showHistory);
  };

  const loadFromHistory = (item: AudioTranscription) => {
    setResult(item);
    setShowHistory(false);
  };

  // ── Reset ──

  const handleReset = () => {
    setFile(null);
    setResult(null);
    setError('');
    setCopied('');
    setRecordedBlob(null);
    setRecordingTime(0);
    setContentType('general');
    setShowExportMenu(false);
    setSearchParams({});
  };

  const formatDuration = (seconds: number): string => {
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, '0')}`;
  };

  const hasSubmittable = (activeTab === 'upload' && file) || (activeTab === 'record' && recordedBlob);

  return (
    <main className="relative pt-20 sm:pt-28 pb-12 sm:pb-16 px-4 sm:px-6">
      {/* Hero */}
      {!result && !isProcessing && (
        <div className="text-center mb-8">
          <motion.div
            initial={{ opacity: 0, scale: 0.9 }}
            animate={{ opacity: 1, scale: 1 }}
            transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
            className="inline-flex items-center gap-2 px-4 py-1.5 rounded-full text-sm font-medium mb-6"
            style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}
          >
            <Mic className="w-4 h-4" />
            Powered by OpenAI Whisper + AI Summary
          </motion.div>

          <motion.h1
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.1 }}
            className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight mb-4"
            style={{ color: 'var(--color-text-primary)' }}
          >
            Audio{' '}
            <span className="bg-clip-text text-transparent"
              style={{ backgroundImage: 'linear-gradient(135deg, var(--color-brand-400), var(--color-brand-600))' }}>
              Intelligence
            </span>
          </motion.h1>

          <motion.p
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.2 }}
            className="text-lg max-w-xl mx-auto mb-2"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            Upload a recording or record live. Get accurate transcriptions and AI-powered summaries with key points, action items, and decisions.
          </motion.p>

          {/* History toggle */}
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.3 }}
            className="flex items-center gap-4 mt-2"
          >
            <button
              onClick={toggleHistory}
              className="inline-flex items-center gap-1.5 text-sm font-medium transition-colors"
              style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}
            >
              <History className="w-4 h-4" />
              {showHistory ? 'Hide history' : 'View recent'}
            </button>
          </motion.div>
        </div>
      )}

      {/* History Panel (MTA-25) */}
      <AnimatePresence>
        {showHistory && !result && (
          <motion.div
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={{ opacity: 0, height: 0 }}
            className="max-w-3xl mx-auto mb-8 overflow-hidden"
          >
            <div className="p-4 rounded-2xl border" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
              <h3 className="text-base font-semibold mb-3 flex items-center gap-2" style={{ color: 'var(--color-text-primary)' }}>
                <History className="w-4 h-4" style={{ color: 'var(--color-brand-500)' }} />
                Recent Transcriptions
              </h3>

              {historyLoading ? (
                <div className="flex items-center justify-center py-8">
                  <Loader2 className="w-5 h-5 animate-spin" style={{ color: 'var(--color-brand-500)' }} />
                </div>
              ) : historyItems.length === 0 ? (
                <p className="text-sm text-center py-6" style={{ color: 'var(--color-text-muted)' }}>No transcriptions yet</p>
              ) : (
                <div className="space-y-2 max-h-72 overflow-y-auto">
                  {historyItems.map((item) => (
                    <button
                      key={item.id}
                      onClick={() => loadFromHistory(item)}
                      className="w-full text-left p-3 rounded-xl border transition-all hover:scale-[1.01]"
                      style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-border)', minHeight: '44px' }}
                    >
                      <div className="flex items-center gap-3">
                        <FileAudio className="w-4 h-4 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-medium truncate" style={{ color: 'var(--color-text-primary)' }}>
                            {item.original_name}
                          </p>
                          <p className="text-xs flex items-center gap-2" style={{ color: 'var(--color-text-muted)' }}>
                            <span>{formatDuration(item.duration)}</span>
                            <span>{item.word_count.toLocaleString()} words</span>
                            {item.summary_status === 'completed' && (
                              <span className="inline-flex items-center gap-0.5">
                                <Sparkles className="w-3 h-3" /> Summarized
                              </span>
                            )}
                          </p>
                        </div>
                        <span className="text-xs shrink-0" style={{ color: 'var(--color-text-muted)' }}>
                          {new Date(item.created_at).toLocaleDateString()}
                        </span>
                      </div>
                    </button>
                  ))}
                </div>
              )}
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Input Tabs: Upload / Record */}
      {!result && !isProcessing && (
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.3 }}
          className="max-w-2xl mx-auto"
        >
          {/* Tab switcher */}
          <div className="flex gap-1 p-1 rounded-xl mb-6 max-w-xs mx-auto"
            style={{ backgroundColor: 'var(--color-surface-overlay)' }}>
            <button
              onClick={() => setActiveTab('upload')}
              className="flex-1 flex items-center justify-center gap-1.5 px-4 py-2.5 rounded-lg text-sm font-medium transition-all"
              style={{
                backgroundColor: activeTab === 'upload' ? 'var(--color-surface-elevated)' : 'transparent',
                color: activeTab === 'upload' ? 'var(--color-text-primary)' : 'var(--color-text-muted)',
                boxShadow: activeTab === 'upload' ? '0 1px 3px rgba(0,0,0,0.1)' : 'none',
                minHeight: '44px',
              }}
            >
              <Upload className="w-4 h-4" /> Upload
            </button>
            <button
              onClick={() => setActiveTab('record')}
              className="flex-1 flex items-center justify-center gap-1.5 px-4 py-2.5 rounded-lg text-sm font-medium transition-all"
              style={{
                backgroundColor: activeTab === 'record' ? 'var(--color-surface-elevated)' : 'transparent',
                color: activeTab === 'record' ? 'var(--color-text-primary)' : 'var(--color-text-muted)',
                boxShadow: activeTab === 'record' ? '0 1px 3px rgba(0,0,0,0.1)' : 'none',
                minHeight: '44px',
              }}
            >
              <Mic className="w-4 h-4" /> Record
            </button>
          </div>

          {/* Upload tab */}
          {activeTab === 'upload' && (
            <>
              <div
                onDrop={handleDrop}
                onDragOver={(e) => { e.preventDefault(); setIsDragging(true); }}
                onDragLeave={(e) => { e.preventDefault(); setIsDragging(false); }}
                onClick={() => inputRef.current?.click()}
                className="relative cursor-pointer rounded-2xl border-2 border-dashed p-12 text-center transition-all duration-300"
                style={{
                  borderColor: isDragging ? 'var(--color-brand-500)' : 'var(--color-border)',
                  backgroundColor: isDragging ? 'var(--color-brand-50)' : 'var(--color-surface-elevated)',
                }}
              >
                <input ref={inputRef} type="file" accept={allowedExtensions.join(',')}
                  onChange={(e) => { const f = e.target.files?.[0]; if (f) handleFile(f); }} className="hidden" />
                <Upload className="w-12 h-12 mx-auto mb-4"
                  style={{ color: isDragging ? 'var(--color-brand-500)' : 'var(--color-text-muted)' }} />
                <p className="text-base font-medium mb-2" style={{ color: 'var(--color-text-primary)' }}>
                  {isDragging ? 'Drop your audio file here' : 'Drag and drop, or click to browse'}
                </p>
                <p className="text-sm" style={{ color: 'var(--color-text-muted)' }}>
                  MP3, WAV, M4A, OGG, FLAC, WebM — Max {maxSizeMB}MB
                </p>
              </div>

              {/* Selected file preview */}
              <AnimatePresence>
                {file && (
                  <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
                    className="mt-4 p-4 rounded-xl border flex items-center gap-3"
                    style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
                    <FileAudio className="w-5 h-5 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium truncate" style={{ color: 'var(--color-text-primary)' }}>{file.name}</p>
                      <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>{(file.size / 1024 / 1024).toFixed(2)} MB</p>
                    </div>
                    <button onClick={(e) => { e.stopPropagation(); setFile(null); }}
                      className="p-1.5 rounded-lg transition-colors hover:opacity-70" style={{ color: 'var(--color-text-muted)' }}>
                      <X className="w-4 h-4" />
                    </button>
                  </motion.div>
                )}
              </AnimatePresence>
            </>
          )}

          {/* Record tab (MTA-23) */}
          {activeTab === 'record' && (
            <div className="rounded-2xl border p-8 text-center"
              style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
              {!isRecording && !recordedBlob && (
                <>
                  <motion.button
                    whileHover={{ scale: 1.05 }}
                    whileTap={{ scale: 0.95 }}
                    onClick={startRecording}
                    className="w-20 h-20 rounded-full flex items-center justify-center mx-auto mb-4 transition-colors"
                    style={{ backgroundColor: '#ef4444', color: 'white' }}
                  >
                    <Mic className="w-8 h-8" />
                  </motion.button>
                  <p className="text-base font-medium" style={{ color: 'var(--color-text-primary)' }}>Tap to start recording</p>
                  <p className="text-sm mt-1" style={{ color: 'var(--color-text-muted)' }}>Record meetings, memos, or anything else</p>
                </>
              )}

              {isRecording && (
                <>
                  <motion.div
                    animate={{ scale: [1, 1.1, 1] }}
                    transition={{ repeat: Infinity, duration: 1.5 }}
                    className="w-20 h-20 rounded-full flex items-center justify-center mx-auto mb-4"
                    style={{ backgroundColor: '#ef4444', color: 'white' }}
                  >
                    <Mic className="w-8 h-8" />
                  </motion.div>
                  <p className="text-2xl font-mono font-bold mb-2" style={{ color: '#ef4444' }}>
                    {formatDuration(recordingTime)}
                  </p>
                  <p className="text-sm mb-4" style={{ color: 'var(--color-text-muted)' }}>Recording...</p>
                  <motion.button
                    whileHover={{ scale: 1.03 }}
                    whileTap={{ scale: 0.97 }}
                    onClick={stopRecording}
                    className="px-6 py-3 rounded-xl font-medium text-white"
                    style={{ backgroundColor: '#ef4444', minHeight: '48px' }}
                  >
                    <span className="flex items-center gap-2">
                      <Square className="w-4 h-4" /> Stop Recording
                    </span>
                  </motion.button>
                </>
              )}

              {recordedBlob && !isRecording && (
                <>
                  <CheckCircle2 className="w-12 h-12 mx-auto mb-3" style={{ color: '#10b981' }} />
                  <p className="text-base font-medium mb-1" style={{ color: 'var(--color-text-primary)' }}>Recording complete</p>
                  <p className="text-sm mb-4" style={{ color: 'var(--color-text-muted)' }}>
                    {formatDuration(recordingTime)} — {(recordedBlob.size / 1024 / 1024).toFixed(2)} MB
                  </p>
                  <button onClick={() => { setRecordedBlob(null); setRecordingTime(0); }}
                    className="text-sm font-medium transition-colors" style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}>
                    Discard and re-record
                  </button>
                </>
              )}
            </div>
          )}

          {/* Content type selector (MTA-24) */}
          {hasSubmittable && (
            <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="mt-4">
              <div className="relative">
                <button
                  onClick={() => setShowTypeDropdown(!showTypeDropdown)}
                  className="w-full flex items-center justify-between px-4 py-3 rounded-xl border text-sm transition-colors"
                  style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)', color: 'var(--color-text-primary)', minHeight: '48px' }}
                >
                  <span className="flex items-center gap-2">
                    {CONTENT_TYPES.find(ct => ct.value === contentType)?.icon}
                    <span className="font-medium">{CONTENT_TYPES.find(ct => ct.value === contentType)?.label}</span>
                    <span style={{ color: 'var(--color-text-muted)' }}>— {CONTENT_TYPES.find(ct => ct.value === contentType)?.desc}</span>
                  </span>
                  <ChevronDown className="w-4 h-4" style={{ color: 'var(--color-text-muted)' }} />
                </button>

                <AnimatePresence>
                  {showTypeDropdown && (
                    <motion.div
                      initial={{ opacity: 0, y: -8 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -8 }}
                      className="absolute z-20 w-full mt-2 rounded-xl border shadow-lg overflow-hidden"
                      style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}
                    >
                      {CONTENT_TYPES.map((ct) => (
                        <button
                          key={ct.value}
                          onClick={() => { setContentType(ct.value); setShowTypeDropdown(false); }}
                          className="w-full flex items-center gap-3 px-4 py-3 text-sm transition-colors text-left"
                          style={{
                            backgroundColor: ct.value === contentType ? 'var(--color-brand-50)' : 'transparent',
                            color: 'var(--color-text-primary)',
                            minHeight: '44px',
                          }}
                        >
                          <span style={{ color: ct.value === contentType ? 'var(--color-brand-500)' : 'var(--color-text-muted)' }}>{ct.icon}</span>
                          <div>
                            <p className="font-medium">{ct.label}</p>
                            <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>{ct.desc}</p>
                          </div>
                        </button>
                      ))}
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            </motion.div>
          )}

          {/* Submit button */}
          {hasSubmittable && (
            <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="mt-6 text-center">
              <motion.button
                whileHover={{ scale: 1.02 }}
                whileTap={{ scale: 0.98 }}
                onClick={handleSubmit}
                className="px-8 py-3 rounded-xl text-white font-medium text-base transition-colors duration-200"
                style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '48px' }}
              >
                <span className="flex items-center gap-2">
                  <Sparkles className="w-5 h-5" />
                  Transcribe{contentType !== 'general' ? ' & Summarize' : ''}
                </span>
              </motion.button>
            </motion.div>
          )}
        </motion.div>
      )}

      {/* Processing state */}
      {isProcessing && (
        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}
          className="max-w-2xl mx-auto p-8 rounded-2xl border text-center"
          style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <Loader2 className="w-8 h-8 animate-spin mx-auto mb-4" style={{ color: 'var(--color-brand-500)' }} />
          <p className="text-lg font-medium" style={{ color: 'var(--color-text-primary)' }}>
            {result?.status === 'pending' ? 'Uploading audio...' : 'Transcribing audio...'}
          </p>
          <p className="text-sm mt-2" style={{ color: 'var(--color-text-secondary)' }}>
            {result?.status === 'processing' 
              ? 'Processing in background — this may take a few minutes for longer files'
              : 'This may take a moment'}
          </p>
        </motion.div>
      )}

      {/* Error */}
      {error && (
        <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
          className="max-w-2xl mx-auto mt-6 p-4 rounded-xl text-sm flex items-center gap-3"
          style={{ backgroundColor: 'rgba(239, 68, 68, 0.1)', border: '1px solid rgba(239, 68, 68, 0.2)', color: '#ef4444' }}>
          <AlertCircle className="w-5 h-5 shrink-0" />
          {error}
        </motion.div>
      )}

      {/* Result */}
      <AnimatePresence>
        {result && result.status === 'completed' && (
          <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
            transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
            className="max-w-3xl mx-auto">

            {/* Top actions */}
            <div className="flex items-center justify-between mb-6">
              <motion.button initial={{ opacity: 0 }} animate={{ opacity: 1 }}
                onClick={handleReset}
                className="flex items-center gap-1.5 text-sm font-medium transition-colors"
                style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}>
                <Mic className="w-4 h-4" /> New transcription
              </motion.button>

              {/* Export dropdown (MTA-26) */}
              <div className="relative">
                <motion.button initial={{ opacity: 0 }} animate={{ opacity: 1 }}
                  onClick={() => setShowExportMenu(!showExportMenu)}
                  className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium border transition-colors"
                  style={{ backgroundColor: 'var(--color-surface-overlay)', borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)', minHeight: '44px' }}>
                  <Download className="w-4 h-4" /> Export <ChevronDown className="w-3 h-3" />
                </motion.button>
                <AnimatePresence>
                  {showExportMenu && (
                    <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -8 }}
                      className="absolute right-0 z-20 mt-2 w-48 rounded-xl border shadow-lg overflow-hidden"
                      style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
                      {[
                        { format: 'txt' as const, label: 'Transcript (.txt)', icon: <FileText className="w-4 h-4" /> },
                        { format: 'md' as const, label: 'Summary (.md)', icon: <Sparkles className="w-4 h-4" /> },
                        { format: 'json' as const, label: 'Raw Data (.json)', icon: <FileAudio className="w-4 h-4" /> },
                      ].map(({ format, label, icon }) => (
                        <button key={format} onClick={() => handleExport(format)}
                          className="w-full flex items-center gap-2 px-4 py-3 text-sm transition-colors text-left hover:opacity-80"
                          style={{ color: 'var(--color-text-primary)', minHeight: '44px' }}>
                          {icon} {label}
                        </button>
                      ))}
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            </div>

            {/* Metadata card */}
            <div className="p-6 rounded-2xl border mb-4"
              style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
              <h2 className="text-xl font-semibold mb-4 tracking-tight flex items-center gap-2"
                style={{ color: 'var(--color-text-primary)' }}>
                <FileAudio className="w-5 h-5" style={{ color: 'var(--color-brand-500)' }} />
                {result.original_name}
              </h2>
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
                <MetaItem icon={<Clock className="w-4 h-4" />} label="Duration" value={formatDuration(result.duration)} />
                <MetaItem icon={<Type className="w-4 h-4" />} label="Words" value={result.word_count.toLocaleString()} />
                <MetaItem icon={<Globe className="w-4 h-4" />} label="Language" value={result.language?.toUpperCase() || 'Unknown'} />
                <MetaItem icon={<Clock className="w-4 h-4" />} label="Processed" value={new Date(result.created_at).toLocaleDateString()} />
              </div>
            </div>

            {/* Summarize button or Summary display (MTA-22) */}
            {result.summary_status !== 'completed' && (
              <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="mb-4">
                {/* Content type selector for summarization */}
                <div className="p-4 rounded-2xl border mb-3"
                  style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
                  <p className="text-sm font-medium mb-2" style={{ color: 'var(--color-text-primary)' }}>Content type for summary:</p>
                  <div className="flex flex-wrap gap-2">
                    {CONTENT_TYPES.map((ct) => (
                      <button key={ct.value}
                        onClick={() => setContentType(ct.value)}
                        className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-xs font-medium border transition-all"
                        style={{
                          backgroundColor: ct.value === contentType ? 'var(--color-brand-50)' : 'var(--color-surface)',
                          borderColor: ct.value === contentType ? 'var(--color-brand-500)' : 'var(--color-border)',
                          color: ct.value === contentType ? 'var(--color-brand-500)' : 'var(--color-text-secondary)',
                          minHeight: '44px',
                        }}>
                        {ct.icon} {ct.label}
                      </button>
                    ))}
                  </div>
                </div>

                <motion.button
                  whileHover={{ scale: 1.02 }}
                  whileTap={{ scale: 0.98 }}
                  onClick={handleSummarize}
                  disabled={isSummarizing}
                  className="w-full px-6 py-3 rounded-xl text-white font-medium text-base transition-colors duration-200 flex items-center justify-center gap-2"
                  style={{ backgroundColor: isSummarizing ? '#9ca3af' : 'var(--color-brand-500)', minHeight: '48px' }}>
                  {isSummarizing ? (
                    <><Loader2 className="w-5 h-5 animate-spin" /> Generating summary...</>
                  ) : (
                    <><Sparkles className="w-5 h-5" /> Generate AI Summary</>
                  )}
                </motion.button>
              </motion.div>
            )}

            {/* Summary results (MTA-22) */}
            {result.summary_status === 'completed' && result.summary_text && (
              <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} className="space-y-4 mb-4">
                {/* Executive Summary */}
                <SectionCard
                  icon={<Sparkles className="w-4 h-4" />}
                  title="Summary"
                  copyLabel="summary"
                  text={result.summary_text}
                  copied={copied}
                  onCopy={() => handleCopy(result.summary_text || '', 'summary')}
                />

                {/* Key Points */}
                {result.key_points && result.key_points.length > 0 && (
                  <SectionCard
                    icon={<Lightbulb className="w-4 h-4" />}
                    title="Key Points"
                    copyLabel="key_points"
                    items={result.key_points}
                    copied={copied}
                    onCopy={() => handleCopy(result.key_points.map((p: string) => `• ${p}`).join('\n'), 'key_points')}
                  />
                )}

                {/* Action Items */}
                {result.action_items && result.action_items.length > 0 && (
                  <SectionCard
                    icon={<ListChecks className="w-4 h-4" />}
                    title="Action Items"
                    copyLabel="action_items"
                    items={result.action_items}
                    isChecklist
                    copied={copied}
                    onCopy={() => handleCopy(result.action_items.map((a: string) => `☐ ${a}`).join('\n'), 'action_items')}
                  />
                )}

                {/* Decisions */}
                {result.decisions && result.decisions.length > 0 && (
                  <SectionCard
                    icon={<CheckCircle2 className="w-4 h-4" />}
                    title="Decisions"
                    copyLabel="decisions"
                    items={result.decisions}
                    copied={copied}
                    onCopy={() => handleCopy(result.decisions.map((d: string) => `• ${d}`).join('\n'), 'decisions')}
                  />
                )}

                {result.summary_model && (
                  <p className="text-xs text-right" style={{ color: 'var(--color-text-muted)' }}>
                    Generated with {result.summary_model}
                  </p>
                )}
              </motion.div>
            )}

            {/* Full Transcript */}
            <div className="p-6 rounded-2xl border"
              style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
              <div className="flex items-center justify-between mb-4">
                <h3 className="text-base font-semibold flex items-center gap-2"
                  style={{ color: 'var(--color-text-primary)' }}>
                  <Mic className="w-4 h-4" style={{ color: 'var(--color-brand-500)' }} />
                  Full Transcript
                </h3>
                <button
                  onClick={() => handleCopy(result.transcript_text, 'transcript')}
                  className="flex items-center gap-1 px-2 py-1.5 rounded-lg text-xs font-medium border transition-colors"
                  style={{
                    backgroundColor: copied === 'transcript' ? '#10b981' : 'var(--color-surface-overlay)',
                    color: copied === 'transcript' ? 'white' : 'var(--color-text-secondary)',
                    borderColor: copied === 'transcript' ? '#10b981' : 'var(--color-border)',
                    minHeight: '36px',
                  }}>
                  {copied === 'transcript' ? <Check className="w-3 h-3" /> : <Copy className="w-3 h-3" />}
                  {copied === 'transcript' ? 'Copied' : 'Copy'}
                </button>
              </div>
              <div className="text-sm leading-relaxed whitespace-pre-wrap max-h-96 overflow-y-auto"
                style={{ color: 'var(--color-text-secondary)' }}>
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
            className="fixed bottom-6 left-1/2 -translate-x-1/2 z-50 flex items-center gap-2 px-4 py-3 rounded-xl shadow-lg"
            style={{ backgroundColor: '#10b981', color: 'white' }}>
            <Check className="w-4 h-4" />
            <span className="text-sm font-medium">Copied to clipboard</span>
          </motion.div>
        )}
      </AnimatePresence>
    </main>
  );
}

// ── Sub-components ──

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

function SectionCard({
  icon, title, text, items, isChecklist, copyLabel, copied, onCopy,
}: {
  icon: React.ReactNode;
  title: string;
  text?: string;
  items?: string[];
  isChecklist?: boolean;
  copyLabel: string;
  copied: string;
  onCopy: () => void;
}) {
  return (
    <div className="p-5 rounded-2xl border"
      style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-base font-semibold flex items-center gap-2"
          style={{ color: 'var(--color-text-primary)' }}>
          <span style={{ color: 'var(--color-brand-500)' }}>{icon}</span>
          {title}
        </h3>
        <button onClick={onCopy}
          className="flex items-center gap-1 px-2 py-1.5 rounded-lg text-xs font-medium border transition-colors"
          style={{
            backgroundColor: copied === copyLabel ? '#10b981' : 'var(--color-surface-overlay)',
            color: copied === copyLabel ? 'white' : 'var(--color-text-secondary)',
            borderColor: copied === copyLabel ? '#10b981' : 'var(--color-border)',
            minHeight: '36px',
          }}>
          {copied === copyLabel ? <Check className="w-3 h-3" /> : <Copy className="w-3 h-3" />}
          {copied === copyLabel ? 'Copied' : 'Copy'}
        </button>
      </div>

      {text && (
        <p className="text-sm leading-relaxed" style={{ color: 'var(--color-text-secondary)' }}>{text}</p>
      )}

      {items && (
        <ul className="space-y-1.5">
          {items.map((item, i) => (
            <li key={i} className="flex items-start gap-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>
              {isChecklist ? (
                <Square className="w-4 h-4 shrink-0 mt-0.5" style={{ color: 'var(--color-text-muted)' }} />
              ) : (
                <span className="w-1.5 h-1.5 rounded-full shrink-0 mt-2" style={{ backgroundColor: 'var(--color-brand-500)' }} />
              )}
              {item}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
