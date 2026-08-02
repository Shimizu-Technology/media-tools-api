import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Link, Navigate, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { AlertCircle, Archive, ArrowLeft, BookOpen, Check, Clock3, Copy, Download, ExternalLink, FileAudio, FileText, FolderPlus, Loader2, Play, RefreshCw, Search, Sparkles, Star, Tag, X } from 'lucide-react';
import { AddToCollectionModal } from '../components/AddToCollectionModal';
import { SummaryPanel } from '../components/SummaryPanel';
import { TranscriptChatPanel } from '../components/TranscriptChatPanel';
import { CitationRow } from '../components/CitationChip';
import {
  downloadAudioExport,
  downloadExport,
  getAudioPlaybackUrl,
  getAudioTranscription,
  getErrorMessage,
  getSummaryErrorMessage,
  getLibraryPreferences,
  getMediaSegments,
  getPDFExtraction,
  getTranscript,
  retryAudioTranscription,
  summarizeAudio,
  updateLibraryPreferences,
  type AudioTranscription,
  type PDFExtraction,
  type Transcript,
  type LibraryPreferences,
  type Citation,
  type MediaSegment,
} from '../lib/api';
import type { ItemDetailType } from '../lib/library';
import { formatTimestamp } from '../lib/citations';

type DetailItem = Transcript | AudioTranscription | PDFExtraction;

export function ItemDetailPage() {
  const { itemType, itemId } = useParams();
  const type = itemType as ItemDetailType;
  const [item, setItem] = useState<DetailItem | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isActing, setIsActing] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);
  const [collectionOpen, setCollectionOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [audioURL, setAudioURL] = useState('');
  const [preferences, setPreferences] = useState<LibraryPreferences>({ favorite: false, archived: false, tags: [] });
  const [tagInput, setTagInput] = useState('');
  const [videoSummaryReady, setVideoSummaryReady] = useState(false);
  const [segments, setSegments] = useState<MediaSegment[]>([]);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const videoRef = useRef<HTMLIFrameElement | null>(null);
  const playerSectionRef = useRef<HTMLElement | null>(null);
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();

  const validType = type === 'transcript' || type === 'audio' || type === 'pdf';
  const markVideoSummaryReady = useCallback(() => setVideoSummaryReady(true), []);

  const loadItem = useCallback(async (quiet = false) => {
    if (!itemId || !validType) return;
    if (!quiet) setIsLoading(true);
    setError('');
    try {
      setItem(type === 'transcript' ? await getTranscript(itemId) : type === 'audio' ? await getAudioTranscription(itemId) : await getPDFExtraction(itemId));
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      if (!quiet) setIsLoading(false);
    }
  }, [itemId, type, validType]);

  useEffect(() => { void loadItem(); }, [loadItem]);

  useEffect(() => {
    if (!itemId || !validType) return;
    getLibraryPreferences(type, itemId).then(setPreferences).catch(() => setPreferences({ favorite: false, archived: false, tags: [] }));
  }, [itemId, type, validType]);

  const status = item?.status || '';
  const audioSummaryStatus = type === 'audio' ? (item as AudioTranscription | null)?.summary_status : 'none';
  useEffect(() => {
    const mediaActive = status === 'pending' || status === 'processing';
    const summaryActive = audioSummaryStatus === 'pending' || audioSummaryStatus === 'processing';
    if (!mediaActive && !summaryActive) return;
    const timer = window.setInterval(() => { void loadItem(true); }, 4000);
    return () => window.clearInterval(timer);
  }, [audioSummaryStatus, loadItem, status]);

  useEffect(() => {
    if (!itemId || !validType || status !== 'completed') {
      setSegments([]);
      return;
    }
    let current = true;
    getMediaSegments(type, itemId)
      .then((result) => { if (current) setSegments(result); })
      .catch(() => { if (current) setSegments([]); });
    return () => { current = false; };
  }, [itemId, status, type, validType]);

  useEffect(() => {
    if (type !== 'audio' || !itemId || !item || item.status === 'pending') return;
    let current = true;
    getAudioPlaybackUrl(itemId).then((result) => { if (current) setAudioURL(result.url); }).catch(() => setAudioURL(''));
    return () => { current = false; };
  }, [item, itemId, type]);

  const view = useMemo(() => normalizeItem(type, item), [item, type]);
  const matchCount = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase();
    if (!needle || !view.text) return 0;
    return view.text.toLocaleLowerCase().split(needle).length - 1;
  }, [query, view.text]);

  const handleCopy = async () => {
    if (!view.text) return;
    await navigator.clipboard.writeText(view.text);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1800);
  };

  const handleExport = async () => {
    if (!item || !itemId) return;
    setIsActing(true);
    setError('');
    try {
      let blob: Blob;
      if (type === 'transcript') blob = await downloadExport(itemId, 'md');
      else if (type === 'audio') blob = await downloadAudioExport(itemId, 'md');
      else blob = new Blob([view.text], { type: 'text/plain;charset=utf-8' });
      downloadBlob(blob, `${safeFilename(view.title)}.${type === 'pdf' ? 'txt' : 'md'}`);
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setIsActing(false);
    }
  };

  const handleRetry = async () => {
    if (type !== 'audio' || !itemId) return;
    setIsActing(true);
    setError('');
    try {
      setItem(await retryAudioTranscription(itemId));
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setIsActing(false);
    }
  };

  const handleAudioSummary = async () => {
    if (type !== 'audio' || !itemId) return;
    setIsActing(true);
    setError('');
    try {
      setItem(await summarizeAudio(itemId, { content_type: (item as AudioTranscription).content_type || 'general', length: 'medium' }));
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setIsActing(false);
    }
  };

  const openCitation = useCallback((citation: Citation) => {
    if (!itemId) return;
    if (citation.item_id !== itemId || citation.item_type !== type) {
      const params = new URLSearchParams();
      if (typeof citation.start_ms === 'number') params.set('t', String(Math.floor(citation.start_ms / 1000)));
      if (typeof citation.page_number === 'number') params.set('page', String(citation.page_number));
      const citationSearch = params.toString();
      navigate(`/app/items/${citation.item_type}/${citation.item_id}${citationSearch ? `?${citationSearch}` : ''}`);
      return;
    }

    if (typeof citation.start_ms === 'number') {
      const seconds = citation.start_ms / 1000;
      setSearchParams((current) => {
        const next = new URLSearchParams(current);
        next.set('t', String(Math.floor(seconds)));
        return next;
      }, { replace: true });
      if (type === 'audio' && audioRef.current) {
        audioRef.current.currentTime = seconds;
        void audioRef.current.play().catch(() => undefined);
      }
      if (type === 'transcript' && videoRef.current?.contentWindow) {
        videoRef.current.contentWindow.postMessage(JSON.stringify({
          event: 'command',
          func: 'seekTo',
          args: [seconds, true],
        }), 'https://www.youtube.com');
        videoRef.current.contentWindow.postMessage(JSON.stringify({
          event: 'command',
          func: 'playVideo',
          args: [],
        }), 'https://www.youtube.com');
      }
      playerSectionRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return;
    }

    if (typeof citation.page_number === 'number') {
      setSearchParams((current) => {
        const next = new URLSearchParams(current);
        next.set('page', String(citation.page_number));
        return next;
      }, { replace: true });
      const target = document.querySelector(`[data-page="${citation.page_number}"]`);
      target?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return;
    }
    document.getElementById(`segment-${citation.segment_id}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }, [itemId, navigate, setSearchParams, type]);

  useEffect(() => {
    if (!item || status !== 'completed') return;
    const timeValue = searchParams.get('t');
    const pageValue = searchParams.get('page');
    const seconds = timeValue === null ? Number.NaN : Number(timeValue);
    const page = pageValue === null ? Number.NaN : Number(pageValue);
    const timer = window.setTimeout(() => {
      if (Number.isFinite(seconds) && seconds >= 0) {
        openCitation({
          segment_id: 'deep-link',
          item_type: type,
          item_id: item.id,
          start_ms: seconds * 1000,
        });
      } else if (Number.isFinite(page) && page > 0) {
        openCitation({
          segment_id: 'deep-link',
          item_type: type,
          item_id: item.id,
          page_number: page,
        });
      }
    }, 500);
    return () => window.clearTimeout(timer);
    // Run once when this item becomes ready; openCitation also normalizes the URL.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item?.id, status]);

  if (!validType) return <Navigate to="/app/library" replace />;

  const savePreferences = async (updates: Partial<LibraryPreferences>) => {
    if (!itemId) return;
    setIsActing(true);
    setError('');
    try {
      setPreferences(await updateLibraryPreferences(type, itemId, updates));
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setIsActing(false);
    }
  };

  const addTag = () => {
    const value = tagInput.trim();
    if (!value || preferences.tags.some((tag) => tag.toLocaleLowerCase() === value.toLocaleLowerCase())) return;
    void savePreferences({ tags: [...preferences.tags, value] });
    setTagInput('');
  };

  if (isLoading) return <CenteredState icon={<Loader2 className="h-6 w-6 animate-spin" />} title="Loading item…" />;
  if (!item) return <CenteredState icon={<AlertCircle className="h-7 w-7" />} title="This item could not be opened" body={error || 'It may have been deleted or you may not have access.'} />;

  const complete = item.status === 'completed';
  const active = item.status === 'pending' || item.status === 'processing';

  return (
    <div className="mx-auto max-w-7xl space-y-6 pb-12">
      <Link to="/app/library" className="inline-flex min-h-11 items-center gap-2 text-sm font-semibold" style={{ color: 'var(--color-text-secondary)' }}><ArrowLeft className="h-4 w-4" /> Back to library</Link>

      <header className="rounded-[2rem] border p-5 sm:p-7" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex flex-col justify-between gap-6 lg:flex-row lg:items-start">
          <div className="min-w-0">
            <div className="mb-3 flex flex-wrap items-center gap-2">
              <TypeBadge type={type} />
              <StatusBadge status={item.status} />
              {(view.summaryReady || videoSummaryReady) && <span className="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}><Sparkles className="h-3 w-3" /> Summarized</span>}
            </div>
            <h1 className="break-words text-2xl font-semibold tracking-tight sm:text-4xl">{view.title}</h1>
            <p className="mt-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>{view.subtitle}</p>
          </div>
          <div className="flex flex-wrap gap-2">
            <ActionButton label={copied ? 'Copied' : 'Copy text'} icon={copied ? Check : Copy} onClick={() => void handleCopy()} disabled={!view.text} />
            <ActionButton label="Export" icon={Download} onClick={() => void handleExport()} disabled={!view.text || isActing} />
            <ActionButton label="Add to collection" icon={FolderPlus} onClick={() => setCollectionOpen(true)} />
            <ActionButton label={preferences.favorite ? 'Starred' : 'Star'} icon={Star} onClick={() => void savePreferences({ favorite: !preferences.favorite })} active={preferences.favorite} disabled={isActing} />
            <ActionButton label={preferences.archived ? 'Unarchive' : 'Archive'} icon={Archive} onClick={() => void savePreferences({ archived: !preferences.archived })} disabled={isActing} />
            {view.sourceURL && <a href={view.sourceURL} target="_blank" rel="noreferrer" className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-3 text-sm font-semibold" style={{ borderColor: 'var(--color-border)' }}>Source <ExternalLink className="h-4 w-4" /></a>}
          </div>
        </div>
        <div className="mt-6 grid grid-cols-2 gap-3 border-t pt-5 sm:grid-cols-4" style={{ borderColor: 'var(--color-border)' }}>
          <Meta label="Created" value={formatDate(view.createdAt)} />
          <Meta label="Words" value={view.wordCount ? view.wordCount.toLocaleString() : '—'} />
          <Meta label={type === 'pdf' ? 'Pages' : 'Duration'} value={type === 'pdf' ? String(view.pageCount || '—') : formatDuration(view.duration)} />
          <Meta label="Language" value={view.language || '—'} />
        </div>
      </header>

      {error && <div role="alert" className="flex items-start gap-3 rounded-2xl border p-4 text-sm" style={{ borderColor: 'var(--color-danger)', color: 'var(--color-danger)', backgroundColor: 'rgba(239, 68, 68, 0.08)' }}><AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />{error}</div>}

      <section className="flex flex-col gap-4 rounded-2xl border p-4 sm:flex-row sm:items-center" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex items-center gap-2 text-sm font-semibold"><Tag className="h-4 w-4" style={{ color: 'var(--color-brand-500)' }} /> Tags</div>
        <div className="flex flex-1 flex-wrap gap-2">
          {preferences.tags.map((tag) => <span key={tag} className="inline-flex min-h-9 items-center gap-1 rounded-full px-3 text-xs font-semibold" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>{tag}<button onClick={() => void savePreferences({ tags: preferences.tags.filter((value) => value !== tag) })} disabled={isActing} className="flex h-7 w-7 items-center justify-center rounded-full disabled:cursor-not-allowed disabled:opacity-40" aria-label={`Remove ${tag} tag`}><X className="h-3 w-3" /></button></span>)}
          {preferences.tags.length === 0 && <span className="text-sm" style={{ color: 'var(--color-text-muted)' }}>Add client, project, or topic labels.</span>}
        </div>
        <div className="flex gap-2">
          <input value={tagInput} onChange={(event) => setTagInput(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') addTag(); }} maxLength={40} placeholder="Add tag" aria-label="New tag" className="min-h-11 min-w-0 flex-1 rounded-xl border bg-transparent px-3 text-sm outline-none sm:w-36" style={{ borderColor: 'var(--color-border)' }} />
          <button onClick={addTag} disabled={!tagInput.trim() || isActing} className="min-h-11 rounded-xl border px-3 text-sm font-semibold disabled:opacity-40" style={{ borderColor: 'var(--color-border)' }}>Add</button>
        </div>
      </section>

      {active && <div className="rounded-2xl border p-5" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}><div className="flex items-center gap-3"><Loader2 className="h-5 w-5 animate-spin" style={{ color: 'var(--color-brand-500)' }} /><div><p className="font-semibold">{view.progressLabel}</p><p className="mt-1 text-sm" style={{ color: 'var(--color-text-secondary)' }}>This page updates automatically. You can safely leave and return later.</p></div></div>{view.progress > 0 && <div className="mt-4 h-2 overflow-hidden rounded-full" style={{ backgroundColor: 'var(--color-surface-overlay)' }}><div className="h-full rounded-full transition-all" style={{ width: `${Math.min(view.progress, 100)}%`, backgroundColor: 'var(--color-brand-500)' }} /></div>}</div>}

      {item.status === 'failed' && <div className="flex flex-col items-start justify-between gap-4 rounded-2xl border p-5 sm:flex-row sm:items-center" style={{ borderColor: 'rgba(239, 68, 68, 0.35)', backgroundColor: 'rgba(239, 68, 68, 0.08)' }}><div><p className="font-semibold" style={{ color: 'var(--color-danger)' }}>Processing failed</p><p className="mt-1 text-sm" style={{ color: 'var(--color-text-secondary)' }}>{view.errorMessage || 'The job could not be completed.'}</p></div>{type === 'audio' && <ActionButton label="Retry transcription" icon={RefreshCw} onClick={() => void handleRetry()} disabled={isActing} />}</div>}

      {type === 'transcript' && complete && <section ref={playerSectionRef} className="overflow-hidden rounded-2xl border" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}><div className="flex items-center gap-2 border-b p-4" style={{ borderColor: 'var(--color-border)' }}><Play className="h-4 w-4" style={{ color: 'var(--color-brand-500)' }} /><h2 className="font-semibold">Source video</h2><span className="ml-auto text-xs" style={{ color: 'var(--color-text-muted)' }}>Citations jump here</span></div><div className="aspect-video bg-black"><iframe ref={videoRef} className="h-full w-full" src={`https://www.youtube.com/embed/${(item as Transcript).youtube_id}?enablejsapi=1&playsinline=1&rel=0&start=${Math.max(0, Number(searchParams.get('t')) || 0)}`} title={`Source video: ${view.title}`} allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowFullScreen /></div></section>}

      {type === 'audio' && audioURL && <section ref={playerSectionRef} className="rounded-2xl border p-5" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}><div className="mb-3 flex items-center gap-2"><Play className="h-4 w-4" style={{ color: 'var(--color-brand-500)' }} /><h2 className="font-semibold">Original recording</h2><span className="ml-auto text-xs" style={{ color: 'var(--color-text-muted)' }}>Citations jump here</span></div><audio ref={audioRef} className="w-full" controls preload="metadata" src={audioURL}>Your browser does not support audio playback.</audio></section>}

      {type === 'audio' && (item as AudioTranscription).quality_warning && <section className="rounded-2xl border p-5" style={{ borderColor: 'rgba(245, 158, 11, 0.4)', backgroundColor: 'rgba(245, 158, 11, 0.08)' }}><div className="flex items-start gap-3"><AlertCircle className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-warning)' }} /><div><h2 className="font-semibold">Partial transcript recovered</h2><p className="mt-1 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{(item as AudioTranscription).quality_warning}</p>{((item as AudioTranscription).omitted_ranges || []).length > 0 && <p className="mt-2 text-xs" style={{ color: 'var(--color-text-muted)' }}>Omitted: {(item as AudioTranscription).omitted_ranges?.map((range) => `${formatDuration(range.start)}–${formatDuration(range.end)}`).join(', ')}</p>}</div></div></section>}

      {complete && <div className="grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(340px,0.65fr)]">
        <div className="space-y-6">
          {type === 'transcript' ? <SummaryPanel transcriptId={item.id} transcriptText={view.text} segments={segments} onCitationClick={openCitation} onSummaryReady={markVideoSummaryReady} /> : <TextViewer title={type === 'pdf' ? 'Document text' : 'Transcript'} text={view.text} segments={segments} query={query} setQuery={setQuery} matches={matchCount} onCitationClick={openCitation} transcriptModes={type === 'audio'} />}
          {type === 'audio' && <AudioSummary item={item as AudioTranscription} onGenerate={handleAudioSummary} isActing={isActing} onCitationClick={openCitation} />}
        </div>
        <aside><TranscriptChatPanel itemId={item.id} itemType={type} onCitationClick={openCitation} /></aside>
      </div>}

      <AddToCollectionModal open={collectionOpen} onClose={() => setCollectionOpen(false)} itemType={type} itemId={item.id} itemTitle={view.title} />
    </div>
  );
}

function TextViewer({ title, text, segments, query, setQuery, matches, onCitationClick, transcriptModes = false }: {
  title: string;
  text: string;
  segments: MediaSegment[];
  query: string;
  setQuery: (value: string) => void;
  matches: number;
  onCitationClick: (citation: Citation) => void;
  transcriptModes?: boolean;
}) {
  const [mode, setMode] = useState<'full' | 'timestamped'>('full');
  const [viewerCopied, setViewerCopied] = useState(false);
  const timedSegments = useMemo(() => segments.filter((segment) => typeof segment.start_ms === 'number'), [segments]);
  const hasTimestampedView = transcriptModes && timedSegments.length > 0;
  const showSegments = transcriptModes ? mode === 'timestamped' && hasTimestampedView : segments.length > 0;
  const visibleSegments = transcriptModes ? timedSegments : segments;
  const plainText = text.trim() || segments.map((segment) => segment.text.trim()).filter(Boolean).join('\n\n');
  const copyText = showSegments && transcriptModes
    ? timedSegments.map((segment) => `[${formatTimestamp(segment.start_ms || 0)}] ${segment.text.trim()}`).join('\n')
    : plainText;
  const copyLabel = showSegments && transcriptModes ? 'Copy timestamped' : transcriptModes ? 'Copy full transcript' : 'Copy text';

  const copyVisibleTranscript = async () => {
    if (!copyText) return;
    await navigator.clipboard.writeText(copyText);
    setViewerCopied(true);
    window.setTimeout(() => setViewerCopied(false), 1800);
  };

  return <section className="overflow-hidden rounded-2xl border" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}><div className="border-b p-4" style={{ borderColor: 'var(--color-border)' }}><div className="flex flex-col justify-between gap-3 lg:flex-row lg:items-center"><div className="flex items-center gap-2"><FileText className="h-4 w-4" style={{ color: 'var(--color-brand-500)' }} /><div><h2 className="font-semibold">{title}</h2>{hasTimestampedView && <p className="mt-0.5 text-xs" style={{ color: 'var(--color-text-muted)' }}>{mode === 'full' ? 'Clean text for reading and copying' : 'Select a timestamp to play that moment'}</p>}</div></div><div className="flex flex-col gap-2 sm:flex-row sm:items-center">{hasTimestampedView && <div className="grid grid-cols-2 rounded-xl border p-1" role="group" aria-label="Transcript view" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}><button type="button" aria-pressed={mode === 'full'} onClick={() => setMode('full')} className="min-h-11 rounded-lg px-3 text-sm font-semibold transition" style={{ backgroundColor: mode === 'full' ? 'var(--color-surface-elevated)' : undefined, color: mode === 'full' ? 'var(--color-text-primary)' : 'var(--color-text-muted)', boxShadow: mode === 'full' ? '0 1px 2px rgba(0, 0, 0, 0.16)' : undefined }}>Full</button><button type="button" aria-pressed={mode === 'timestamped'} onClick={() => setMode('timestamped')} className="min-h-11 rounded-lg px-3 text-sm font-semibold transition" style={{ backgroundColor: mode === 'timestamped' ? 'var(--color-surface-elevated)' : undefined, color: mode === 'timestamped' ? 'var(--color-text-primary)' : 'var(--color-text-muted)', boxShadow: mode === 'timestamped' ? '0 1px 2px rgba(0, 0, 0, 0.16)' : undefined }}>Timestamped</button></div>}<button type="button" onClick={() => void copyVisibleTranscript()} disabled={!copyText} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-3 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)] disabled:opacity-40" style={{ borderColor: 'var(--color-border)' }}>{viewerCopied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}{viewerCopied ? 'Copied' : copyLabel}</button><div className="relative"><Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2" style={{ color: 'var(--color-text-muted)' }} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find in text" aria-label="Find in text" className="min-h-11 w-full rounded-xl border bg-transparent pl-9 pr-10 text-sm outline-none sm:w-56" style={{ borderColor: 'var(--color-border)' }} />{query && <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs" style={{ color: 'var(--color-text-muted)' }}>{matches}</span>}</div></div></div></div><div className="max-h-[70vh] overflow-y-auto p-4 text-sm leading-7 sm:p-5" style={{ color: 'var(--color-text-secondary)' }}>{showSegments ? <div className="space-y-1">{visibleSegments.map((segment) => {
    const location = typeof segment.start_ms === 'number' ? formatTimestamp(segment.start_ms) : typeof segment.page_number === 'number' ? `Page ${segment.page_number}` : 'Source';
    return <button id={`segment-${segment.id}`} data-page={segment.page_number} type="button" key={segment.id} onClick={() => onCitationClick({ segment_id: segment.id, item_type: segment.item_type, item_id: segment.item_id, start_ms: segment.start_ms, end_ms: segment.end_ms, page_number: segment.page_number })} className="grid w-full grid-cols-[4.5rem_minmax(0,1fr)] gap-3 rounded-xl px-3 py-2 text-left transition hover:bg-[var(--color-surface-overlay)]"><span className="font-mono text-xs font-semibold" style={{ color: 'var(--color-brand-500)' }}>{location}</span><span>{renderHighlighted(segment.text, query)}</span></button>;
  })}</div> : <div className="whitespace-pre-wrap px-2 py-1">{renderHighlighted(plainText, query)}</div>}</div></section>;
}

function AudioSummary({ item, onGenerate, isActing, onCitationClick }: { item: AudioTranscription; onGenerate: () => void; isActing: boolean; onCitationClick: (citation: Citation) => void }) {
  const hasSummary = Boolean(item.summary_text);
  const pending = item.summary_status === 'pending' || item.summary_status === 'processing';
  const buttonLabel = isActing ? 'Starting summary' : pending ? 'Generating in background' : item.summary_status === 'failed' ? 'Try again' : hasSummary ? 'Regenerate' : 'Generate summary';

  return (
    <section className="rounded-2xl border p-5 sm:p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
      <div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-center">
        <div className="flex items-center gap-2">
          <Sparkles className="h-4 w-4" style={{ color: 'var(--color-brand-500)' }} />
          <h2 className="font-semibold">AI summary</h2>
        </div>
        <button onClick={onGenerate} disabled={isActing || pending} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 text-sm font-semibold text-white disabled:opacity-50" style={{ backgroundColor: 'var(--color-brand-500)' }}>
          {isActing || pending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Sparkles className="h-4 w-4" />}
          {buttonLabel}
        </button>
      </div>
      {pending && <p className="mt-4 text-sm" style={{ color: 'var(--color-text-secondary)' }}>You can leave this page or start another upload. The summary will keep running.</p>}
      {item.summary_status === 'failed' && (
        <div role="alert" className="mt-4 flex items-start gap-3 rounded-xl border p-4" style={{ borderColor: 'rgba(239, 68, 68, 0.3)', backgroundColor: 'rgba(239, 68, 68, 0.08)' }}>
          <AlertCircle className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-danger)' }} />
          <div>
            <p className="text-sm font-semibold">Summary couldn't be generated</p>
            <p className="mt-1 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{getSummaryErrorMessage(item.summary_error_message)}</p>
          </div>
        </div>
      )}
      {hasSummary ? (
        <div className="mt-5 space-y-5">
          <div><p className="whitespace-pre-wrap text-sm leading-7" style={{ color: 'var(--color-text-secondary)' }}>{item.summary_text}</p><CitationRow citations={item.summary_evidence?.summary} onClick={onCitationClick} /></div>
          <ListBlock title="Key points" items={item.key_points} citations={item.summary_evidence?.key_points} onCitationClick={onCitationClick} />
          <ListBlock title="Action items" items={item.action_items} citations={item.summary_evidence?.action_items} onCitationClick={onCitationClick} />
          <ListBlock title="Decisions" items={item.decisions} citations={item.summary_evidence?.decisions} onCitationClick={onCitationClick} />
        </div>
      ) : !pending && item.summary_status !== 'failed' && (
        <p className="mt-4 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Create structured notes, key points, decisions, and action items from this recording.</p>
      )}
    </section>
  );
}

function ListBlock({ title, items, citations, onCitationClick }: { title: string; items: string[]; citations?: Citation[][]; onCitationClick: (citation: Citation) => void }) {
  if (!items?.length) return null;
  return <div><h3 className="mb-2 text-sm font-semibold">{title}</h3><ul className="space-y-3">{items.map((value, index) => <li key={`${title}-${index}`} className="flex gap-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}><span style={{ color: 'var(--color-brand-500)' }}>•</span><span className="min-w-0">{value}<CitationRow citations={citations?.[index]} onClick={onCitationClick} /></span></li>)}</ul></div>;
}

function ActionButton({ label, icon: Icon, onClick, disabled = false, active = false }: { label: string; icon: typeof Copy; onClick: () => void; disabled?: boolean; active?: boolean }) {
  return <button onClick={onClick} disabled={disabled} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-3 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)] disabled:opacity-40" style={{ borderColor: active ? 'var(--color-brand-500)' : 'var(--color-border)', backgroundColor: active ? 'var(--color-brand-50)' : undefined, color: active ? 'var(--color-brand-500)' : undefined }}><Icon className="h-4 w-4" />{label}</button>;
}

function Meta({ label, value }: { label: string; value: string }) { return <div><p className="text-xs uppercase tracking-wider" style={{ color: 'var(--color-text-muted)' }}>{label}</p><p className="mt-1 truncate text-sm font-semibold">{value}</p></div>; }

function TypeBadge({ type }: { type: ItemDetailType }) { const content = type === 'transcript' ? ['Video', FileText] as const : type === 'audio' ? ['Recording', FileAudio] as const : ['PDF', BookOpen] as const; const Icon = content[1]; return <span className="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold" style={{ backgroundColor: 'var(--color-surface-subtle)', color: 'var(--color-text-secondary)' }}><Icon className="h-3 w-3" />{content[0]}</span>; }
function StatusBadge({ status }: { status: string }) { return <span className="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold capitalize" style={{ backgroundColor: 'var(--color-surface-subtle)', color: status === 'completed' ? 'var(--color-success)' : status === 'failed' ? 'var(--color-danger)' : 'var(--color-warning)' }}>{status === 'pending' || status === 'processing' ? <Clock3 className="h-3 w-3" /> : null}{status}</span>; }

function CenteredState({ icon, title, body }: { icon: ReactNode; title: string; body?: string }) { return <div className="mx-auto flex min-h-[50vh] max-w-lg flex-col items-center justify-center text-center"><div className="flex h-14 w-14 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-surface-elevated)', color: 'var(--color-brand-500)' }}>{icon}</div><h1 className="mt-5 text-xl font-semibold">{title}</h1>{body && <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{body}</p>}<Link to="/app/library" className="mt-5 inline-flex min-h-11 items-center gap-2 text-sm font-semibold" style={{ color: 'var(--color-brand-500)' }}><ArrowLeft className="h-4 w-4" /> Back to library</Link></div>; }

function normalizeItem(type: ItemDetailType, item: DetailItem | null) {
  if (!item) return { title: '', subtitle: '', text: '', wordCount: 0, duration: 0, pageCount: 0, language: '', createdAt: '', sourceURL: '', errorMessage: '', summaryReady: false, progress: 0, progressLabel: '' };
  if (type === 'transcript') { const value = item as Transcript; return { title: value.title || 'Untitled video', subtitle: value.channel_name || 'Video transcript', text: value.transcript_text || '', wordCount: value.word_count, duration: value.duration, pageCount: 0, language: value.language, createdAt: value.created_at, sourceURL: value.youtube_url, errorMessage: value.error_message || '', summaryReady: false, progress: value.status === 'completed' ? 100 : 0, progressLabel: value.status === 'pending' ? 'Waiting to process video…' : 'Extracting transcript…' }; }
  if (type === 'audio') { const value = item as AudioTranscription; return { title: value.original_name || 'Untitled recording', subtitle: value.content_type?.replaceAll('_', ' ') || 'Audio transcription', text: value.transcript_text || '', wordCount: value.word_count, duration: value.duration, pageCount: 0, language: value.language, createdAt: value.created_at, sourceURL: '', errorMessage: value.error_message || '', summaryReady: value.summary_status === 'completed', progress: value.processing_progress || 0, progressLabel: audioProgressLabel(value.processing_stage) }; }
  const value = item as PDFExtraction; return { title: value.original_name || 'Untitled PDF', subtitle: `${value.page_count} ${value.page_count === 1 ? 'page' : 'pages'}`, text: value.text_content || '', wordCount: value.word_count, duration: 0, pageCount: value.page_count, language: '', createdAt: value.created_at, sourceURL: '', errorMessage: value.error_message || '', summaryReady: false, progress: value.status === 'completed' ? 100 : 0, progressLabel: 'Extracting document text…' };
}

function audioProgressLabel(stage?: string) { switch (stage) { case 'downloading': return 'Preparing source audio…'; case 'transcoding': return 'Optimizing the recording…'; case 'chunking': return 'Splitting long audio safely…'; case 'transcribing': return 'Transcribing audio…'; case 'stitching': return 'Combining transcript chunks…'; default: return 'Waiting to transcribe…'; } }
function formatDate(value: string) { const date = new Date(value); return Number.isNaN(date.getTime()) ? '—' : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date); }
function formatDuration(seconds?: number) { if (!seconds || seconds < 1) return '—'; const h = Math.floor(seconds / 3600); const m = Math.floor((seconds % 3600) / 60); const s = Math.floor(seconds % 60); return h ? `${h}h ${m}m` : m ? `${m}m ${s}s` : `${s}s`; }
function safeFilename(value: string) { return value.replace(/\.[^.]+$/, '').replace(/[^a-z0-9-_]+/gi, '_').replace(/^_+|_+$/g, '') || 'media-tools-export'; }
function downloadBlob(blob: Blob, filename: string) { const url = URL.createObjectURL(blob); const anchor = document.createElement('a'); anchor.href = url; anchor.download = filename; document.body.appendChild(anchor); anchor.click(); anchor.remove(); URL.revokeObjectURL(url); }
function renderHighlighted(text: string, query: string): ReactNode { const needle = query.trim(); if (!needle) return text; const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); return text.split(new RegExp(`(${escaped})`, 'gi')).map((part, index) => part.toLocaleLowerCase() === needle.toLocaleLowerCase() ? <mark key={index} className="rounded px-0.5" style={{ backgroundColor: 'var(--color-brand-50)', color: 'inherit' }}>{part}</mark> : part); }
