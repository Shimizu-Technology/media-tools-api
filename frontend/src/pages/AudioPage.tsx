import { useState, useCallback, useRef, useEffect } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
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
  Pencil,
  Save,
  RefreshCw,
  Pause,
  Play,
  ArrowRight,
} from 'lucide-react';
import {
  transcribeAudio,
  presignAudioUpload,
  uploadAudioToPresignedUrl,
  completeAudioUpload,
  getAudioTranscription,
  renameAudioTranscription,
  retryAudioTranscription,
  cancelAudioTranscription,
  summarizeAudio,
  downloadAudioExport,
  listAudioTranscriptions,
  getAudioPlaybackUrl,
  getSummaryErrorMessage,
  type AudioTranscription,
  type AudioContentType,
  type APIError,
} from '../lib/api';
import { usePolling } from '../hooks/usePolling';
import { TranscriptChatPanel } from '../components/TranscriptChatPanel';
import { CapturePageHeader } from '../components/CapturePageHeader';

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

const PENDING_AUDIO_DB = 'media-tools-audio';
const PENDING_AUDIO_STORE = 'pending-recordings';
const PENDING_AUDIO_KEY = 'latest';
const ACTIVE_AUDIO_TRANSCRIPTION_KEY = 'mta_active_audio_transcription_id';
const ALLOWED_AUDIO_EXTENSIONS = ['.mp3', '.wav', '.m4a', '.mp4', '.ogg', '.flac', '.webm'];
const MAX_AUDIO_SIZE_MB = 2048;

interface PendingRecording {
  blob: Blob;
  mimeType: string;
  durationSeconds: number;
  createdAt: number;
}

function isActiveTranscription(transcription: AudioTranscription | null | undefined): boolean {
  return transcription?.status === 'pending' || transcription?.status === 'processing';
}

function getAudioProcessingLabel(transcription: AudioTranscription): string {
  const stage = transcription.processing_stage || '';
  if (stage === 'downloading') return 'Preparing source audio';
  if (stage === 'transcoding') return 'Preparing recording';
  if (stage === 'chunking') return 'Splitting long audio';
  if (stage === 'transcribing') return 'Transcribing audio';
  if (stage === 'stitching') return 'Combining transcript';
  if (transcription.status === 'pending') return 'Waiting for a worker';
  return 'Processing recording';
}

function getAudioProcessingProgress(transcription: AudioTranscription): number {
  return Math.min(100, Math.max(0, transcription.processing_progress || 0));
}

function formatElapsedTime(createdAt: string, now: number): string {
  const startedAt = Date.parse(createdAt);
  if (!Number.isFinite(startedAt)) return 'Started recently';

  const totalSeconds = Math.max(0, Math.floor((now - startedAt) / 1000));
  if (totalSeconds < 60) return `${totalSeconds}s elapsed`;

  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes}m elapsed`;
  return `${minutes}m elapsed`;
}

function syncActiveJobList(
  jobs: AudioTranscription[],
  transcription: AudioTranscription,
): AudioTranscription[] {
  const withoutCurrent = jobs.filter((job) => job.id !== transcription.id);
  return isActiveTranscription(transcription) ? [transcription, ...withoutCurrent] : withoutCurrent;
}

function getStoredActiveTranscriptionID(): string | null {
  try {
    return localStorage.getItem(ACTIVE_AUDIO_TRANSCRIPTION_KEY);
  } catch {
    return null;
  }
}

function storeActiveTranscriptionID(id: string): void {
  try {
    localStorage.setItem(ACTIVE_AUDIO_TRANSCRIPTION_KEY, id);
  } catch {
    // Best-effort resume only; polling still works while this page is mounted.
  }
}

function clearStoredActiveTranscriptionID(id?: string): void {
  try {
    const current = localStorage.getItem(ACTIVE_AUDIO_TRANSCRIPTION_KEY);
    if (!id || current === id) {
      localStorage.removeItem(ACTIVE_AUDIO_TRANSCRIPTION_KEY);
    }
  } catch {
    // Nothing to clean up if storage is unavailable.
  }
}

function syncActiveTranscription(transcription: AudioTranscription): void {
  if (isActiveTranscription(transcription)) {
    storeActiveTranscriptionID(transcription.id);
  } else {
    clearStoredActiveTranscriptionID(transcription.id);
  }
}

function pickRecordingMimeType(): string {
  const candidates = [
    'audio/mp4;codecs=mp4a.40.2',
    'audio/mp4',
    'audio/webm;codecs=opus',
    'audio/webm',
  ];
  for (const candidate of candidates) {
    if (MediaRecorder.isTypeSupported(candidate)) return candidate;
  }
  return '';
}

function extensionForMimeType(mimeType: string): string {
  const normalized = mimeType.toLowerCase();
  if (normalized.includes('mp4') || normalized.includes('m4a')) return 'm4a';
  if (normalized.includes('ogg')) return 'ogg';
  return 'webm';
}

async function measureBlobDurationSeconds(blob: Blob): Promise<number | null> {
  if (typeof Audio === 'undefined') return null;
  return await new Promise<number | null>((resolve) => {
    const audio = new Audio();
    const url = URL.createObjectURL(blob);
    let settled = false;
    const done = (value: number | null) => {
      if (settled) return;
      settled = true;
      URL.revokeObjectURL(url);
      resolve(value);
    };
    audio.preload = 'metadata';
    audio.onloadedmetadata = () => {
      const duration = Number.isFinite(audio.duration) ? audio.duration : NaN;
      done(Number.isFinite(duration) && duration > 0 ? duration : null);
    };
    audio.onerror = () => done(null);
    audio.src = url;
  });
}

function openPendingAudioDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(PENDING_AUDIO_DB, 1);
    req.onupgradeneeded = () => {
      req.result.createObjectStore(PENDING_AUDIO_STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function savePendingRecording(recording: PendingRecording): Promise<void> {
  if (typeof indexedDB === 'undefined') return;
  const db = await openPendingAudioDB();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(PENDING_AUDIO_STORE, 'readwrite');
    tx.objectStore(PENDING_AUDIO_STORE).put(recording, PENDING_AUDIO_KEY);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function loadPendingRecording(): Promise<PendingRecording | null> {
  if (typeof indexedDB === 'undefined') return null;
  const db = await openPendingAudioDB();
  return await new Promise<PendingRecording | null>((resolve, reject) => {
    const tx = db.transaction(PENDING_AUDIO_STORE, 'readonly');
    const req = tx.objectStore(PENDING_AUDIO_STORE).get(PENDING_AUDIO_KEY);
    req.onsuccess = () => resolve((req.result as PendingRecording) || null);
    req.onerror = () => reject(req.error);
  });
}

async function clearPendingRecording(): Promise<void> {
  if (typeof indexedDB === 'undefined') return;
  const db = await openPendingAudioDB();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(PENDING_AUDIO_STORE, 'readwrite');
    tx.objectStore(PENDING_AUDIO_STORE).delete(PENDING_AUDIO_KEY);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

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
  const [isRecordingPaused, setIsRecordingPaused] = useState(false);
  const [recordingTime, setRecordingTime] = useState(0);
  const recordingTimeRef = useRef(0);
  const [recordedBlob, setRecordedBlob] = useState<Blob | null>(null);
  const [recordedMimeType, setRecordedMimeType] = useState('audio/webm');
  const [recordingCaptureWarning, setRecordingCaptureWarning] = useState('');
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const streamRef = useRef<MediaStream | null>(null);

  const [activeJobs, setActiveJobs] = useState<AudioTranscription[]>([]);
  const [activeJobsLoading, setActiveJobsLoading] = useState(true);
  const [activeJobsError, setActiveJobsError] = useState('');
  const [activeJobsClock, setActiveJobsClock] = useState(() => Date.now());
  const activeJobsMountedRef = useRef(true);
  const activeJobsRefreshInFlightRef = useRef(false);
  const activeJobsRefreshQueuedRef = useRef(false);
  const activeJobsMutationVersionRef = useRef(0);
  const terminalJobIDsRef = useRef(new Set<string>());
  const refreshActiveJobsRef = useRef<(showLoading?: boolean) => Promise<void>>(async () => {});
  const backgroundActiveJobCount = activeJobs.filter((job) => job.id !== result?.id).length;

  // Export state (MTA-26)
  const [showExportMenu, setShowExportMenu] = useState(false);
  const [playbackUrl, setPlaybackUrl] = useState('');
  const [showPlayback, setShowPlayback] = useState(false);
  const [isLoadingPlayback, setIsLoadingPlayback] = useState(false);
  const [isRetrying, setIsRetrying] = useState(false);
  const [isCanceling, setIsCanceling] = useState(false);
  const [isRenaming, setIsRenaming] = useState(false);
  const [renameValue, setRenameValue] = useState('');
  const [isSavingRename, setIsSavingRename] = useState(false);
  const [isDirectUploading, setIsDirectUploading] = useState(false);
  const [isServerUploading, setIsServerUploading] = useState(false);
  const [directUploadProgress, setDirectUploadProgress] = useState(0);
  const [recoveredDraft, setRecoveredDraft] = useState(false);
  const [draftAudioUrl, setDraftAudioUrl] = useState('');

  // Tab state: 'upload' | 'record'
  const [activeTab, setActiveTab] = useState<'upload' | 'record'>('upload');

  // Cleanup on unmount
  useEffect(() => {
    activeJobsMountedRef.current = true;
    return () => {
      activeJobsMountedRef.current = false;
      if (timerRef.current) clearInterval(timerRef.current);
      if (streamRef.current) streamRef.current.getTracks().forEach(t => t.stop());
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    loadPendingRecording()
      .then((saved) => {
        if (cancelled || !saved || result || searchParams.get('id') || getStoredActiveTranscriptionID()) return;
        setActiveTab('record');
        setRecordedBlob(saved.blob);
        setRecordedMimeType(saved.mimeType || 'audio/webm');
        setRecordingTime(saved.durationSeconds);
        setRecoveredDraft(true);
        setDraftAudioUrl(URL.createObjectURL(saved.blob));
      })
      .catch(() => {
        // Best-effort recovery only.
      });
    return () => {
      cancelled = true;
    };
  }, [result, searchParams]);

  useEffect(() => {
    return () => {
      if (draftAudioUrl) {
        URL.revokeObjectURL(draftAudioUrl);
      }
    };
  }, [draftAudioUrl]);

  const refreshActiveJobs = useCallback(async (showLoading = false) => {
    if (activeJobsRefreshInFlightRef.current) {
      activeJobsRefreshQueuedRef.current = true;
      return;
    }
    activeJobsRefreshInFlightRef.current = true;
    const mutationVersion = activeJobsMutationVersionRef.current;
    if (showLoading) setActiveJobsLoading(true);
    try {
      const transcriptions = await listAudioTranscriptions({ status: 'active' });
      if (!activeJobsMountedRef.current) return;
      if (mutationVersion === activeJobsMutationVersionRef.current) {
        setActiveJobs(transcriptions.filter(isActiveTranscription));
        setActiveJobsError('');
      } else {
        // A submission, retry, cancellation, or completion changed local state
        // while this request was running. Preserve that newer state and fetch
        // one authoritative replacement as soon as this request releases.
        activeJobsRefreshQueuedRef.current = true;
      }
    } catch {
      if (!activeJobsMountedRef.current) return;
      if (mutationVersion === activeJobsMutationVersionRef.current) {
        setActiveJobsError('Active transcription progress could not be refreshed. Your jobs are still processing in the background.');
      } else {
        // The failed request is stale too. Queue a replacement so discovery
        // cannot stop after an optimistic local mutation.
        activeJobsRefreshQueuedRef.current = true;
      }
    } finally {
      activeJobsRefreshInFlightRef.current = false;
      if (showLoading && activeJobsMountedRef.current) setActiveJobsLoading(false);
      if (activeJobsMountedRef.current && activeJobsRefreshQueuedRef.current) {
        activeJobsRefreshQueuedRef.current = false;
        queueMicrotask(() => void refreshActiveJobsRef.current());
      }
    }
  }, []);

  useEffect(() => {
    refreshActiveJobsRef.current = refreshActiveJobs;
  }, [refreshActiveJobs]);

  useEffect(() => {
    void refreshActiveJobs(true);
  }, [refreshActiveJobs]);

  useEffect(() => {
    // The selected job already has its own two-second poll. Poll the collection
    // only when at least one additional job needs background monitoring.
    if (backgroundActiveJobCount === 0 && !activeJobsError) return;

    const refreshTimer = window.setInterval(() => {
      if (document.visibilityState === 'visible') {
        void refreshActiveJobs();
      }
    }, 3000);
    const clockTimer = window.setInterval(() => setActiveJobsClock(Date.now()), 1000);

    return () => {
      window.clearInterval(refreshTimer);
      window.clearInterval(clockTimer);
    };
  }, [activeJobsError, backgroundActiveJobCount, refreshActiveJobs]);

  // Restore active transcription progress after navigation, refresh, or returning to this page.
  useEffect(() => {
    if (result) return;

    let cancelled = false;
    const id = searchParams.get('id');
    const storedID = getStoredActiveTranscriptionID();

    const restore = async () => {
      if (!id && storedID) {
        setSearchParams({ id: storedID }, { replace: true });
        return;
      }

      if (id) {
        try {
          const transcription = await getAudioTranscription(id);
          if (cancelled) return;
          setResult(transcription);
          setIsProcessing(isActiveTranscription(transcription));
          syncActiveTranscription(transcription);
        } catch {
          if (!cancelled) {
            clearStoredActiveTranscriptionID(id);
            setError('Transcription not found');
          }
        }
        return;
      }

      // No URL or stored active ID means there is no explicit job to restore.
      // This keeps "Start over" from being undone by discovering the same
      // still-running backend job in history.
    };

    void restore();

    return () => {
      cancelled = true;
    };
  }, [searchParams, result, setSearchParams]);

  const validateFile = useCallback((f: File): string | null => {
    const ext = '.' + f.name.split('.').pop()?.toLowerCase();
    if (!ALLOWED_AUDIO_EXTENSIONS.includes(ext)) {
      return `Unsupported format "${ext}". Supported: ${ALLOWED_AUDIO_EXTENSIONS.join(', ')}`;
    }
    if (f.size > MAX_AUDIO_SIZE_MB * 1024 * 1024) {
      return `File too large (${(f.size / 1024 / 1024).toFixed(1)}MB). Max: ${MAX_AUDIO_SIZE_MB}MB`;
    }
    return null;
  }, []);

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
    setRecordingCaptureWarning('');
  }, [validateFile]);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragging(false);
    const droppedFile = e.dataTransfer.files[0];
    if (droppedFile) handleFile(droppedFile);
  }, [handleFile]);

  // ── Recording (MTA-23) ──

  const stopRecordingTimer = () => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
  };

  const startRecordingTimer = () => {
    stopRecordingTimer();
    timerRef.current = setInterval(() => {
      setRecordingTime(prev => {
        const next = prev + 1;
        recordingTimeRef.current = next;
        return next;
      });
    }, 1000);
  };

  const startRecording = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;

      const preferredMimeType = pickRecordingMimeType();
      const recorder = preferredMimeType
        ? new MediaRecorder(stream, { mimeType: preferredMimeType })
        : new MediaRecorder(stream);
      const effectiveMimeType = recorder.mimeType || preferredMimeType || 'audio/webm';
      setRecordedMimeType(effectiveMimeType);
      mediaRecorderRef.current = recorder;
      chunksRef.current = [];
      setRecordingCaptureWarning('');

      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };

      recorder.onstop = () => {
        void (async () => {
          const blob = new Blob(chunksRef.current, { type: effectiveMimeType });
          const measuredDuration = await measureBlobDurationSeconds(blob);
          const displayDuration = measuredDuration ? Math.max(1, Math.round(measuredDuration)) : recordingTimeRef.current;

          setRecordedBlob(blob);
          setRecordingTime(displayDuration);
          setRecordedMimeType(effectiveMimeType);

          if (recordingTimeRef.current >= 120 && blob.size < 1024 * 1024) {
            setRecordingCaptureWarning(
              'This recording file looks incomplete for its shown length. Please re-record and keep the app in foreground.'
            );
          } else if (measuredDuration !== null && recordingTimeRef.current >= 120 && measuredDuration < 10) {
            setRecordingCaptureWarning(
              'Recording appears truncated on this device. Please retry and keep the screen/app active while recording.'
            );
          } else {
            setRecordingCaptureWarning('');
          }

          stream.getTracks().forEach(t => t.stop());
          streamRef.current = null;
          savePendingRecording({
            blob,
            mimeType: effectiveMimeType,
            durationSeconds: displayDuration,
            createdAt: Date.now(),
          }).catch(() => {
            // Local durability is best-effort; upload durability handles backend path.
          });
        })();
      };

      recorder.start(1000); // Collect data every second
      setIsRecording(true);
      setIsRecordingPaused(false);
      setRecordingTime(0);
      recordingTimeRef.current = 0;
      setError('');
      startRecordingTimer();
    } catch {
      setError('Microphone access denied. Please allow microphone access and try again.');
    }
  };

  const stopRecording = () => {
    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== 'inactive') {
      mediaRecorderRef.current.stop();
    }
    stopRecordingTimer();
    setIsRecording(false);
    setIsRecordingPaused(false);
  };

  const pauseRecording = () => {
    const recorder = mediaRecorderRef.current;
    if (!recorder || recorder.state !== 'recording') return;

    // Flush the current timeslice before pausing so browsers do not hold the
    // last spoken seconds in an unfinished internal buffer.
    recorder.requestData();
    recorder.pause();
    stopRecordingTimer();
    setIsRecordingPaused(true);
  };

  const resumeRecording = () => {
    const recorder = mediaRecorderRef.current;
    if (!recorder || recorder.state !== 'paused') return;

    recorder.resume();
    setIsRecordingPaused(false);
    startRecordingTimer();
  };

  // ── Polling for async transcription completion ──

  const shouldPoll =
    result?.status === 'pending' ||
    result?.status === 'processing' ||
    result?.summary_status === 'pending' ||
    result?.summary_status === 'processing';

  usePolling(
    useCallback(async () => {
      if (!result?.id) throw new Error('No result');
      const updated = await getAudioTranscription(result.id);
      setResult(updated);
      if (isActiveTranscription(updated)) {
        terminalJobIDsRef.current.delete(updated.id);
      } else if (!terminalJobIDsRef.current.has(updated.id)) {
        // A completed media job may keep polling while its summary finishes.
        // Invalidate collection refreshes only once for that terminal transition.
        terminalJobIDsRef.current.add(updated.id);
        activeJobsMutationVersionRef.current += 1;
      }
      setActiveJobs((jobs) => syncActiveJobList(jobs, updated));
      syncActiveTranscription(updated);
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
      shouldStop: (data: AudioTranscription) => {
        const mediaDone = data.status === 'completed' || data.status === 'failed';
        const summaryDone = data.summary_status !== 'pending' && data.summary_status !== 'processing';
        return mediaDone && summaryDone;
      },
    }
  );

  // ── Submit (upload or recording) ──

  const handleSubmit = async () => {
    let uploadFile: File;

    if (activeTab === 'record' && recordedBlob) {
      if (recordingCaptureWarning) {
        setError('Recording looks incomplete. Please re-record before transcribing.');
        return;
      }
      const timestamp = new Date().toISOString().slice(0, 19).replace(/[T:]/g, '-');
      const ext = extensionForMimeType(recordedBlob.type || recordedMimeType);
      uploadFile = new File([recordedBlob], `recording-${timestamp}.${ext}`, {
        type: recordedBlob.type || recordedMimeType,
      });
    } else if (file) {
      uploadFile = file;
    } else {
      return;
    }

    setIsProcessing(true);
    setError('');
    setRecoveredDraft(false);
    setDirectUploadProgress(0);

    try {
      let transcription: AudioTranscription;
      try {
        setIsDirectUploading(true);
        const presign = await presignAudioUpload(uploadFile);
        await uploadAudioToPresignedUrl(presign.upload_url, uploadFile, {
          onProgress: setDirectUploadProgress,
        });
        transcription = await completeAudioUpload({
          object_key: presign.object_key,
          original_name: uploadFile.name,
          size_bytes: uploadFile.size,
        });
      } catch {
        // Fallback to server-upload flow for environments without S3 direct upload.
        setIsDirectUploading(false);
        setIsServerUploading(true);
        transcription = await transcribeAudio(uploadFile);
      } finally {
        setIsDirectUploading(false);
        setIsServerUploading(false);
      }
      setDirectUploadProgress(0);
      setResult(transcription);
      terminalJobIDsRef.current.delete(transcription.id);
      activeJobsMutationVersionRef.current += 1;
      setActiveJobs((jobs) => syncActiveJobList(jobs, transcription));
      setActiveJobsClock(Date.now());
      syncActiveTranscription(transcription);
      setSearchParams({ id: transcription.id }, { replace: true });
      if (activeTab === 'record') {
        clearPendingRecording().catch(() => {});
      }
      if (draftAudioUrl) {
        URL.revokeObjectURL(draftAudioUrl);
        setDraftAudioUrl('');
      }
      setRecoveredDraft(false);
      // Don't set isProcessing to false here - polling will do that
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Transcription failed. Please try again.');
      setIsProcessing(false);
      setDirectUploadProgress(0);
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

  const loadFromHistory = (item: AudioTranscription) => {
    setResult(item);
    setIsProcessing(isActiveTranscription(item));
    syncActiveTranscription(item);
    setSearchParams({ id: item.id }, { replace: true });
    setPlaybackUrl('');
    setShowPlayback(false);
  };

  // ── Reset ──

  const handleReset = () => {
    if (result && isActiveTranscription(result)) {
      setActiveJobs((jobs) => syncActiveJobList(jobs, result));
      setActiveJobsClock(Date.now());
    }
    setFile(null);
    setResult(null);
    // Starting another submission only detaches this form from the selected job.
    // The durable worker keeps running, and activeJobs continues to monitor it.
    setIsProcessing(false);
    setError('');
    setCopied('');
    setRecordedBlob(null);
    setRecordedMimeType('audio/webm');
    setRecordingCaptureWarning('');
    setRecordingTime(0);
    setContentType('general');
    setShowExportMenu(false);
    setPlaybackUrl('');
    setShowPlayback(false);
    setIsLoadingPlayback(false);
    setRecoveredDraft(false);
    setIsDirectUploading(false);
    setIsServerUploading(false);
    setDirectUploadProgress(0);
    clearStoredActiveTranscriptionID();
    if (draftAudioUrl) {
      URL.revokeObjectURL(draftAudioUrl);
      setDraftAudioUrl('');
    }
    setSearchParams({});
    clearPendingRecording().catch(() => {});
  };

  const handleRetryStoredAudio = async () => {
    if (!result) return;
    setIsRetrying(true);
    setError('');
    try {
      const updated = await retryAudioTranscription(result.id);
      setResult(updated);
      terminalJobIDsRef.current.delete(updated.id);
      activeJobsMutationVersionRef.current += 1;
      setActiveJobs((jobs) => syncActiveJobList(jobs, updated));
      syncActiveTranscription(updated);
      setSearchParams({ id: updated.id }, { replace: true });
      setIsProcessing(true);
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Retry failed. Please try again.');
    } finally {
      setIsRetrying(false);
    }
  };

  const handleCancelTranscription = async () => {
    if (!result) return;
    setIsCanceling(true);
    setError('');
    try {
      const updated = await cancelAudioTranscription(result.id);
      setResult(updated);
      terminalJobIDsRef.current.add(updated.id);
      activeJobsMutationVersionRef.current += 1;
      setActiveJobs((jobs) => syncActiveJobList(jobs, updated));
      syncActiveTranscription(updated);
      setIsProcessing(false);
      setError('');
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Stop failed. Please try again.');
    } finally {
      setIsCanceling(false);
    }
  };

  const startRename = () => {
    if (!result) return;
    setRenameValue(result.original_name);
    setIsRenaming(true);
  };

  const saveRename = async () => {
    if (!result) return;
    const nextName = renameValue.trim();
    if (!nextName || nextName === result.original_name) {
      setIsRenaming(false);
      return;
    }
    setIsSavingRename(true);
    setError('');
    try {
      const updated = await renameAudioTranscription(result.id, nextName);
      setResult(updated);
      setIsRenaming(false);
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Rename failed. Please try again.');
    } finally {
      setIsSavingRename(false);
    }
  };

  const handleLoadPlayback = async () => {
    if (!result) return;
    if (showPlayback) {
      setShowPlayback(false);
      return;
    }
    if (playbackUrl) {
      setShowPlayback(true);
      return;
    }
    setIsLoadingPlayback(true);
    try {
      const res = await getAudioPlaybackUrl(result.id);
      setPlaybackUrl(res.url);
      setShowPlayback(true);
    } catch {
      setError('Playback URL could not be generated for this transcription.');
    } finally {
      setIsLoadingPlayback(false);
    }
  };

  const formatDuration = (seconds: number): string => {
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, '0')}`;
  };

  const processingLabel = (() => {
    if (isDirectUploading) return 'Uploading directly to secure storage...';
    if (isServerUploading) return 'Uploading through the API...';
    if (result) return `${getAudioProcessingLabel(result)}...`;
    return 'Transcribing recording...';
  })();

  const processingDetail = (() => {
    const stage = result?.processing_stage || '';
    if (stage === 'transcoding') return 'Extracting and compressing audio. Large Zoom recordings can take several minutes.';
    if (stage === 'chunking') return 'Breaking a long recording into safe transcription chunks.';
    if (stage === 'transcribing') return 'Sending audio to Whisper and collecting transcript text.';
    if (result?.status === 'processing' || result?.status === 'pending') return 'Processing in background — long recordings may take several minutes.';
    if (isDirectUploading) return 'Keep this page open while the upload finishes. If it stalls, we will retry through the API.';
    return 'This may take a moment';
  })();

  const hasSubmittable = (activeTab === 'upload' && file) || (activeTab === 'record' && recordedBlob);
  const canEditInput = (!result || result.status === 'failed') && !isProcessing;
  const backgroundActiveJobs = activeJobs.filter((job) => job.id !== result?.id);

  return (
    <main className="relative pb-12 sm:pb-16">
      {!result && !isProcessing && (
        <CapturePageHeader
          icon={Mic}
          eyebrow="Recording"
          title="Record or upload audio"
          description="Capture a conversation in the browser or upload an existing recording, then turn it into a searchable transcript and structured notes."
          historyTo="/app/library?type=audio"
          historyLabel="View recording library"
          highlights={['Record in your browser', 'Files up to 2 GB', 'Runs in the background']}
        />
      )}

      {recoveredDraft && recordedBlob && !result && (
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          className="max-w-3xl mx-auto mb-6 p-4 rounded-2xl border"
          style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}
        >
          <div className="flex items-center justify-between gap-4 flex-wrap">
            <div>
              <p className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>Recovered draft recording</p>
              <p className="text-xs" style={{ color: 'var(--color-text-secondary)' }}>
                We restored an unsent recording from your device so you can upload it safely.
              </p>
            </div>
            <div className="flex items-center gap-2">
              <button
                onClick={() => setActiveTab('record')}
                className="px-3 py-2 rounded-lg text-sm font-medium border"
                style={{ borderColor: 'var(--color-brand-400)', color: 'var(--color-brand-500)', minHeight: '44px' }}
              >
                Resume upload
              </button>
              <button
                onClick={handleReset}
                className="px-3 py-2 rounded-lg text-sm font-medium border"
                style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)', minHeight: '44px' }}
              >
                Discard
              </button>
            </div>
          </div>
          {draftAudioUrl && (
            <div className="mt-3">
              <audio controls src={draftAudioUrl} className="w-full" />
            </div>
          )}
        </motion.div>
      )}

      {/* Input Tabs: Upload / Record */}
      {canEditInput && (
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
                <input ref={inputRef} type="file" accept={ALLOWED_AUDIO_EXTENSIONS.join(',')}
                  onChange={(e) => { const f = e.target.files?.[0]; if (f) handleFile(f); }} className="hidden" />
                <Upload className="w-12 h-12 mx-auto mb-4"
                  style={{ color: isDragging ? 'var(--color-brand-500)' : 'var(--color-text-muted)' }} />
                <p className="text-base font-medium mb-2" style={{ color: 'var(--color-text-primary)' }}>
                  {isDragging ? 'Drop your recording here' : 'Drag and drop a recording, or click to browse'}
                </p>
                <p className="text-sm" style={{ color: 'var(--color-text-muted)' }}>
                  Zoom MP4/M4A, MP3, WAV, OGG, FLAC, WebM — Max {MAX_AUDIO_SIZE_MB}MB
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
                    aria-label="Start recording"
                    className="w-20 h-20 rounded-full flex items-center justify-center mx-auto mb-4 transition-colors"
                    style={{ backgroundColor: 'var(--color-error)', color: 'white' }}
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
                    animate={isRecordingPaused ? { scale: 1 } : { scale: [1, 1.1, 1] }}
                    transition={isRecordingPaused ? undefined : { repeat: Infinity, duration: 1.5 }}
                    className="w-20 h-20 rounded-full flex items-center justify-center mx-auto mb-4"
                    style={{
                      backgroundColor: isRecordingPaused ? 'var(--color-warning)' : 'var(--color-error)',
                      color: 'white',
                    }}
                  >
                    {isRecordingPaused ? <Pause className="w-8 h-8" /> : <Mic className="w-8 h-8" />}
                  </motion.div>
                  <p className="text-2xl font-mono font-bold mb-2" style={{ color: isRecordingPaused ? 'var(--color-warning)' : 'var(--color-error)' }}>
                    {formatDuration(recordingTime)}
                  </p>
                  <p className="text-sm mb-4" style={{ color: 'var(--color-text-muted)' }}>
                    {isRecordingPaused ? 'Paused — paused time is not included' : 'Recording...'}
                  </p>
                  <div className="flex flex-wrap items-center justify-center gap-3">
                    <motion.button
                      whileHover={{ scale: 1.03 }}
                      whileTap={{ scale: 0.97 }}
                      onClick={isRecordingPaused ? resumeRecording : pauseRecording}
                      className="px-6 py-3 rounded-xl font-medium border"
                      style={{
                        borderColor: 'var(--color-brand-400)',
                        color: 'var(--color-brand-500)',
                        minHeight: '48px',
                      }}
                    >
                      <span className="flex items-center gap-2">
                        {isRecordingPaused ? <Play className="w-4 h-4" /> : <Pause className="w-4 h-4" />}
                        {isRecordingPaused ? 'Resume Recording' : 'Pause Recording'}
                      </span>
                    </motion.button>
                    <motion.button
                      whileHover={{ scale: 1.03 }}
                      whileTap={{ scale: 0.97 }}
                      onClick={stopRecording}
                      className="px-6 py-3 rounded-xl font-medium text-white"
                      style={{ backgroundColor: 'var(--color-error)', minHeight: '48px' }}
                    >
                      <span className="flex items-center gap-2">
                        <Square className="w-4 h-4" /> Stop Recording
                      </span>
                    </motion.button>
                  </div>
                </>
              )}

              {recordedBlob && !isRecording && (
                <>
                  <CheckCircle2 className="w-12 h-12 mx-auto mb-3" style={{ color: 'var(--color-success)' }} />
                  <p className="text-base font-medium mb-1" style={{ color: 'var(--color-text-primary)' }}>Recording complete</p>
                  <p className="text-sm mb-4" style={{ color: 'var(--color-text-muted)' }}>
                    {formatDuration(recordingTime)} — {(recordedBlob.size / 1024 / 1024).toFixed(2)} MB
                  </p>
                  {recordingCaptureWarning && (
                    <p className="text-sm mb-3" style={{ color: 'var(--color-error)' }}>
                      {recordingCaptureWarning}
                    </p>
                  )}
                  <button onClick={() => {
                    setRecordedBlob(null);
                    setRecordingTime(0);
                    setRecordedMimeType('audio/webm');
                    setRecordingCaptureWarning('');
                    clearPendingRecording().catch(() => {});
                  }}
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
              <p className="text-xs mt-2" style={{ color: 'var(--color-text-muted)' }}>
                Content type tunes AI summary structure only (it does not change transcription accuracy).
              </p>
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

      {(backgroundActiveJobs.length > 0 || activeJobsError) && (
        <ActiveTranscriptionsPanel
          jobs={backgroundActiveJobs}
          now={activeJobsClock}
          isLoading={activeJobsLoading}
          error={activeJobsError}
          onOpen={loadFromHistory}
          onRefresh={() => void refreshActiveJobs(true)}
        />
      )}

      {/* Failed state helper actions */}
      {result?.status === 'failed' && !isProcessing && (
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          className="mx-auto mt-4 flex max-w-2xl flex-col items-stretch justify-between gap-3 rounded-xl border p-3 sm:flex-row sm:items-center"
          style={{
            backgroundColor: 'var(--color-surface-elevated)',
            borderColor: 'var(--color-border)',
          }}
        >
          <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
            Transcription failed. You can re-transcribe from the saved recording.
          </p>
          <div className="grid grid-cols-2 gap-2 sm:flex sm:items-center">
            {result.audio_s3_key && (
              <button
                onClick={handleRetryStoredAudio}
                disabled={isRetrying}
                className="px-3 py-2 rounded-lg text-sm font-medium border"
                style={{
                  borderColor: 'var(--color-brand-400)',
                  color: 'var(--color-brand-500)',
                  minHeight: '44px',
                }}
              >
                <span className="inline-flex items-center gap-1.5">
                  <RefreshCw className={`w-4 h-4 ${isRetrying ? 'animate-spin' : ''}`} />
                  {isRetrying ? 'Re-transcribing...' : 'Re-transcribe'}
                </span>
              </button>
            )}
            <button
              onClick={handleReset}
              className="px-3 py-2 rounded-lg text-sm font-medium border"
              style={{
                borderColor: 'var(--color-border)',
                color: 'var(--color-text-secondary)',
                minHeight: '44px',
              }}
            >
              Start over
            </button>
          </div>
        </motion.div>
      )}

      {/* Processing state */}
      {isProcessing && (
        <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}
          className="max-w-2xl mx-auto p-8 rounded-2xl border text-center"
          style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <Loader2 className="w-8 h-8 animate-spin mx-auto mb-4" style={{ color: 'var(--color-brand-500)' }} />
          <p className="text-lg font-medium" style={{ color: 'var(--color-text-primary)' }}>
            {processingLabel}
          </p>
          <p className="text-sm mt-2" style={{ color: 'var(--color-text-secondary)' }}>
            {processingDetail}
          </p>
          {isDirectUploading && directUploadProgress > 0 && (
            <div className="mt-4 max-w-md mx-auto">
              <div className="h-2 rounded-full" style={{ backgroundColor: 'var(--color-surface-subtle)' }}>
                <div
                  className="h-2 rounded-full transition-all"
                  style={{
                    width: `${Math.min(100, Math.max(0, directUploadProgress))}%`,
                    backgroundColor: 'var(--color-brand-500)',
                  }}
                />
              </div>
              <p className="text-xs mt-2" style={{ color: 'var(--color-text-muted)' }}>
                {directUploadProgress}% uploaded
              </p>
            </div>
          )}
          {typeof result?.processing_progress === 'number' && result.processing_progress > 0 && (
            <div className="mt-4 max-w-md mx-auto">
              <div className="h-2 rounded-full" style={{ backgroundColor: 'var(--color-surface-subtle)' }}>
                <div
                  className="h-2 rounded-full transition-all"
                  style={{
                    width: `${Math.min(100, Math.max(0, result.processing_progress))}%`,
                    backgroundColor: 'var(--color-brand-500)',
                  }}
                />
              </div>
              <p className="text-xs mt-2" style={{ color: 'var(--color-text-muted)' }}>
                {result.processing_progress}% complete
              </p>
            </div>
          )}
          {result && (result.status === 'pending' || result.status === 'processing') && (
            <button
              onClick={handleCancelTranscription}
              disabled={isCanceling}
              className="mt-5 px-4 py-2 rounded-lg text-sm font-medium border"
              style={{
                borderColor: 'var(--color-border)',
                color: 'var(--color-text-secondary)',
                minHeight: '44px',
              }}
            >
              {isCanceling ? 'Stopping...' : 'Stop processing'}
            </button>
          )}
          {result && (
            <div className="mt-5 flex flex-wrap justify-center gap-2">
              <button
                onClick={handleReset}
                className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-4 text-sm font-semibold"
                style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}
              >
                <Mic className="h-4 w-4" /> Start another
              </button>
              <Link
                to="/app/processing"
                className="inline-flex min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold"
                style={{ color: 'var(--color-brand-500)' }}
              >
                <History className="h-4 w-4" /> View all jobs
              </Link>
            </div>
          )}
        </motion.div>
      )}

      {/* Error */}
      {error && (
        <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
          className="max-w-2xl mx-auto mt-6 p-4 rounded-xl text-sm flex items-center gap-3"
          style={{ backgroundColor: 'rgba(239, 68, 68, 0.12)', border: '1px solid rgba(239, 68, 68, 0.24)', color: 'var(--color-error)' }}>
          <AlertCircle className="w-5 h-5 shrink-0" />
          {error}
        </motion.div>
      )}

      {/* Result */}
      <AnimatePresence>
        {result && result.status === 'completed' && (
          <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
            transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
            className="max-w-5xl mx-auto">

            {/* Top actions */}
            <div className="flex items-center justify-between gap-3 mb-6 flex-wrap">
              <motion.button initial={{ opacity: 0 }} animate={{ opacity: 1 }}
                onClick={handleReset}
                className="flex items-center gap-1.5 text-sm font-medium transition-colors"
                style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}>
                <Mic className="w-4 h-4" /> New transcription
              </motion.button>

              <button
                onClick={handleLoadPlayback}
                className="flex items-center gap-1.5 text-sm font-medium transition-colors"
                style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}
              >
                <FileAudio className="w-4 h-4" />
                {isLoadingPlayback ? 'Loading audio...' : showPlayback ? 'Hide recording' : 'Replay recording'}
              </button>

              {result.audio_s3_key && (
                <button
                  onClick={handleRetryStoredAudio}
                  disabled={isRetrying}
                  className="flex items-center gap-1.5 text-sm font-medium transition-colors disabled:opacity-60"
                  style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}
                  title="Run transcription again from the saved original recording"
                >
                  <RefreshCw className={`w-4 h-4 ${isRetrying ? 'animate-spin' : ''}`} />
                  {isRetrying ? 'Re-transcribing...' : 'Re-transcribe'}
                </button>
              )}

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

            {showPlayback && playbackUrl && (
              <div className="mb-4 rounded-2xl border p-4" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-elevated)' }}>
                <div className="flex items-center justify-between mb-3">
                  <p className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>
                    Original Recording
                  </p>
                  <button
                    onClick={() => setShowPlayback(false)}
                    className="text-xs px-2 py-1 rounded-md border"
                    style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}
                  >
                    Close
                  </button>
                </div>
                <audio controls src={playbackUrl} className="w-full" />
              </div>
            )}

            {result.quality_warning && (
              <div
                className="mb-4 rounded-2xl border p-4"
                style={{
                  borderColor: 'color-mix(in srgb, var(--color-warning) 35%, transparent)',
                  backgroundColor: 'color-mix(in srgb, var(--color-warning) 10%, transparent)',
                }}
              >
                <div className="flex items-start gap-3">
                  <AlertCircle className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-warning)' }} />
                  <div>
                    <p className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>
                      Transcript recovered with gaps
                    </p>
                    <p className="mt-1 text-sm" style={{ color: 'var(--color-text-secondary)' }}>
                      {result.quality_warning}
                    </p>
                    {result.omitted_ranges && result.omitted_ranges.length > 0 && (
                      <p className="mt-2 text-xs" style={{ color: 'var(--color-text-muted)' }}>
                        Omitted: {result.omitted_ranges.map((range) => (
                          `${formatDuration(Math.max(0, Math.floor(range.start)))}–${formatDuration(Math.max(0, Math.ceil(range.end)))}`
                        )).join(', ')}
                      </p>
                    )}
                  </div>
                </div>
              </div>
            )}

            {/* Metadata card */}
            <div className="p-6 rounded-2xl border mb-4"
              style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
              <div className="mb-4 flex items-center gap-3">
                <FileAudio className="w-5 h-5 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
                {isRenaming ? (
                  <div className="flex flex-1 flex-col gap-2 sm:flex-row">
                    <input
                      autoFocus
                      value={renameValue}
                      onChange={(e) => setRenameValue(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter') void saveRename();
                        if (e.key === 'Escape') setIsRenaming(false);
                      }}
                      className="min-w-0 flex-1 rounded-xl border px-3 py-2 text-base font-semibold outline-none"
                      style={{
                        backgroundColor: 'var(--color-surface)',
                        borderColor: 'var(--color-border)',
                        color: 'var(--color-text-primary)',
                        minHeight: '44px',
                      }}
                    />
                    <button
                      onClick={() => void saveRename()}
                      disabled={isSavingRename}
                      className="inline-flex items-center justify-center gap-2 rounded-xl px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
                      style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '44px' }}
                    >
                      {isSavingRename ? <Loader2 className="w-4 h-4 animate-spin" /> : <Save className="w-4 h-4" />}
                      Save
                    </button>
                  </div>
                ) : (
                  <>
                    <h2 className="min-w-0 flex-1 text-xl font-semibold tracking-tight truncate"
                      style={{ color: 'var(--color-text-primary)' }}>
                      {result.original_name}
                    </h2>
                    <button
                      onClick={startRename}
                      className="inline-flex items-center gap-1.5 rounded-lg border px-3 py-2 text-sm font-medium"
                      style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)', minHeight: '44px' }}
                    >
                      <Pencil className="w-4 h-4" />
                      Rename
                    </button>
                  </>
                )}
              </div>
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
                  disabled={isSummarizing || result.summary_status === 'pending' || result.summary_status === 'processing'}
                  className="w-full px-6 py-3 rounded-xl text-white font-medium text-base transition-colors duration-200 flex items-center justify-center gap-2"
                  style={{ backgroundColor: isSummarizing ? '#9ca3af' : 'var(--color-brand-500)', minHeight: '48px' }}>
                  {isSummarizing || result.summary_status === 'pending' || result.summary_status === 'processing' ? (
                    <><Loader2 className="w-5 h-5 animate-spin" /> Generating in background...</>
                  ) : (
                    <><Sparkles className="w-5 h-5" /> {result.summary_status === 'failed' ? 'Try AI Summary Again' : 'Generate AI Summary'}</>
                  )}
                </motion.button>
                {(result.summary_status === 'pending' || result.summary_status === 'processing') && (
                  <p className="mt-3 text-center text-sm" style={{ color: 'var(--color-text-secondary)' }}>
                    You can start another transcription or leave this page. This summary will keep running.
                  </p>
                )}
                {result.summary_status === 'failed' && (
                  <div
                    role="alert"
                    className="mt-3 flex items-start gap-3 rounded-xl border p-4 text-left"
                    style={{ borderColor: 'rgba(239, 68, 68, 0.3)', backgroundColor: 'rgba(239, 68, 68, 0.08)' }}
                  >
                    <AlertCircle className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-danger)' }} />
                    <div>
                      <p className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>Summary couldn't be generated</p>
                      <p className="mt-1 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
                        {getSummaryErrorMessage(result.summary_error_message)}
                      </p>
                    </div>
                  </div>
                )}
              </motion.div>
            )}

            {/* Summary results (MTA-22) */}
            {result.summary_status === 'completed' && result.summary_text && (
              <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} className="space-y-4 mb-4">
                <div className="flex justify-end">
                  <Link to={`/app/items/audio/${result.id}`} className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-border)', color: 'var(--color-brand-500)' }}>
                    <Clock className="h-4 w-4" /> Open timestamped summary
                  </Link>
                </div>
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

            <div className="mt-6 grid gap-6 lg:grid-cols-[1.4fr_0.9fr]">
              <div className="lg:col-span-2 h-px" style={{ backgroundColor: 'var(--color-border)' }} />
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
                      backgroundColor: copied === 'transcript' ? 'var(--color-success)' : 'var(--color-surface-overlay)',
                      color: copied === 'transcript' ? 'white' : 'var(--color-text-secondary)',
                      borderColor: copied === 'transcript' ? 'var(--color-success)' : 'var(--color-border)',
                      minHeight: '44px',
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

              {/* AI Chat */}
              <div>
                <TranscriptChatPanel itemType="audio" itemId={result.id} />
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
            style={{ backgroundColor: 'var(--color-success)', color: 'white' }}>
            <Check className="w-4 h-4" />
            <span className="text-sm font-medium">Copied to clipboard</span>
          </motion.div>
        )}
      </AnimatePresence>
    </main>
  );
}

// ── Sub-components ──

function ActiveTranscriptionsPanel({
  jobs,
  now,
  isLoading,
  error,
  onOpen,
  onRefresh,
}: {
  jobs: AudioTranscription[];
  now: number;
  isLoading: boolean;
  error: string;
  onOpen: (job: AudioTranscription) => void;
  onRefresh: () => void;
}) {
  return (
    <motion.section
      initial={{ opacity: 0, y: 16 }}
      animate={{ opacity: 1, y: 0 }}
      aria-labelledby="active-transcriptions-heading"
      className="mx-auto mt-8 max-w-4xl overflow-hidden rounded-[1.75rem] border"
      style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}
    >
      <div className="flex flex-col justify-between gap-4 border-b px-5 py-5 sm:flex-row sm:items-center sm:px-6" style={{ borderColor: 'var(--color-border)' }}>
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h2 id="active-transcriptions-heading" className="text-lg font-semibold">Active transcriptions</h2>
            {jobs.length > 0 && (
              <span className="rounded-full px-2.5 py-1 text-xs font-semibold" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
                {jobs.length} {jobs.length === 1 ? 'job' : 'jobs'}
              </span>
            )}
          </div>
          <p className="mt-1 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
            Upload or record another item at any time. Jobs run in parallel when capacity is available and remain safe in the background.
          </p>
        </div>
        <button
          type="button"
          onClick={onRefresh}
          disabled={isLoading}
          className="inline-flex min-h-11 shrink-0 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)] disabled:opacity-50"
          style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}
        >
          <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
          Refresh
        </button>
      </div>

      {error && (
        <div role="status" className="border-b px-5 py-3 text-sm sm:px-6" style={{ borderColor: 'var(--color-border)', color: 'var(--color-warning)' }}>
          {error}
        </div>
      )}

      {isLoading && jobs.length === 0 ? (
        <div className="flex min-h-32 items-center justify-center gap-3 px-6" style={{ color: 'var(--color-text-secondary)' }}>
          <Loader2 className="h-5 w-5 animate-spin" /> Checking active jobs...
        </div>
      ) : jobs.length > 0 ? (
        <div className="divide-y" style={{ borderColor: 'var(--color-border)' }}>
          {jobs.map((job) => {
            const progress = getAudioProcessingProgress(job);
            const statusLabel = job.status === 'pending' ? 'Queued' : 'In progress';
            return (
              <button
                type="button"
                key={job.id}
                onClick={() => onOpen(job)}
                className="group grid min-h-28 w-full gap-4 px-5 py-5 text-left transition hover:bg-[var(--color-nav-hover)] sm:grid-cols-[minmax(0,1fr)_auto] sm:px-6"
              >
                <div className="min-w-0">
                  <div className="flex min-w-0 flex-wrap items-center gap-2">
                    <FileAudio className="h-4 w-4 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
                    <p className="min-w-0 truncate text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>{job.original_name}</p>
                    <span className="rounded-full px-2 py-0.5 text-xs font-semibold" style={{ backgroundColor: 'var(--color-surface-subtle)', color: job.status === 'pending' ? 'var(--color-warning)' : 'var(--color-brand-500)' }}>
                      {statusLabel}
                    </span>
                  </div>

                  <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>
                    <span className="inline-flex items-center gap-1.5"><Clock className="h-3.5 w-3.5" />{formatElapsedTime(job.created_at, now)}</span>
                    <span>{getAudioProcessingLabel(job)}</span>
                    <span>{progress}% complete</span>
                  </div>

                  <div
                    className="mt-3 h-2 overflow-hidden rounded-full"
                    role="progressbar"
                    aria-label={`${job.original_name} transcription progress`}
                    aria-valuemin={0}
                    aria-valuemax={100}
                    aria-valuenow={progress}
                    style={{ backgroundColor: 'var(--color-surface-subtle)' }}
                  >
                    <div
                      className="h-full rounded-full transition-[width] duration-500 ease-out"
                      style={{ width: `${progress}%`, backgroundColor: 'var(--color-brand-500)' }}
                    />
                  </div>
                </div>

                <span className="inline-flex min-h-11 items-center gap-2 self-center text-sm font-semibold" style={{ color: 'var(--color-brand-500)' }}>
                  Open <ArrowRight className="h-4 w-4 transition-transform duration-200 group-hover:translate-x-1" />
                </span>
              </button>
            );
          })}
        </div>
      ) : null}
    </motion.section>
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
            backgroundColor: copied === copyLabel ? 'var(--color-success)' : 'var(--color-surface-overlay)',
            color: copied === copyLabel ? 'white' : 'var(--color-text-secondary)',
            borderColor: copied === copyLabel ? 'var(--color-success)' : 'var(--color-border)',
            minHeight: '44px',
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
