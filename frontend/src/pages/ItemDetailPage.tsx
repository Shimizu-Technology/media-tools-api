import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, Navigate, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { AlertCircle, AlignLeft, Archive, ChevronLeft, Copy, Download, ExternalLink, FolderPlus, Loader2, MessageSquare, MoreHorizontal, Pencil, Play, RefreshCw, RotateCcw, Square, Star, Tag, Trash2, X } from 'lucide-react';
import {
  cancelAudioTranscription,
  createSummary,
  deleteAudioTranscription,
  deletePDFExtraction,
  deleteTranscript,
  downloadAudioExport,
  downloadExport,
  formatAudioTranscript,
  getAudioPlaybackUrl,
  getAudioTranscription,
  getErrorMessage,
  getLibraryPreferences,
  getMediaSegments,
  getPDFExtraction,
  getProcessingPreferences,
  getSummaries,
  getTranscript,
  renameAudioTranscription,
  retryAudioTranscription,
  summarizeAudio,
  updateLibraryPreferences,
  type AudioContentType,
  type AudioTranscription,
  type Citation,
  type ExportFormat,
  type LibraryPreferences,
  type MediaSegment,
  type PDFExtraction,
  type Summary,
  type Transcript,
} from '../lib/api';
import { deepLinkAction, parseDeepLink } from '../lib/deepLink';
import { downloadBlob } from '../lib/download';
import { displayTitle, type ItemDetailType } from '../lib/library';
import { formatClock, formatDuration, formatItemDate, pluralize } from '../lib/format';
import { notifyLibraryActivityChanged } from '../lib/libraryActivityEvents';
import { addVideoLink } from '../lib/mediaUpload';
import { parseKeyPoints } from '../lib/summaries';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { AddToCollectionModal } from '../components/AddToCollectionModal';
import { ChatPanel } from '../components/ChatPanel';
import { AudioPlayer, type PlayerHandle } from '../components/item/AudioPlayer';
import { SummarySection, type SummaryView } from '../components/item/SummarySection';
import { TranscriptSection } from '../components/item/TranscriptSection';
import { Menu, type MenuItem } from '../components/ui/Menu';
import { Dialog } from '../components/ui/Dialog';
import { Button, ButtonLink } from '../components/ui/Button';
import { Input, Notice } from '../components/ui/Field';
import { APP_ROUTES } from '../lib/appRoutes';

type DetailItem = Transcript | AudioTranscription | PDFExtraction;

const CONTENT_TYPES: { value: AudioContentType; label: string }[] = [
  { value: 'general', label: 'General' },
  { value: 'meeting', label: 'Meeting' },
  { value: 'phone_call', label: 'Phone call' },
  { value: 'voice_memo', label: 'Voice memo' },
  { value: 'interview', label: 'Interview' },
  { value: 'lecture', label: 'Lecture' },
];

function isActive(status?: string) {
  return status === 'pending' || status === 'processing';
}

/** Poll while something is moving: soon at first, then less often, never giving up. */
function useBackoffRefresh(active: boolean, refresh: () => Promise<void>) {
  const refreshRef = useRef(refresh);
  useEffect(() => { refreshRef.current = refresh; }, [refresh]);
  useEffect(() => {
    if (!active) return;
    let delay = 3000;
    let timer = 0;
    let stopped = false;
    const tick = async () => {
      if (document.visibilityState === 'visible') await refreshRef.current().catch(() => undefined);
      if (stopped) return;
      delay = Math.min(Math.round(delay * 1.4), 30000);
      timer = window.setTimeout(() => void tick(), delay);
    };
    timer = window.setTimeout(() => void tick(), delay);
    const onVisible = () => {
      if (document.visibilityState !== 'visible') return;
      delay = 3000;
      window.clearTimeout(timer);
      void tick();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      stopped = true;
      window.clearTimeout(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [active]);
}

export function ItemDetailPage() {
  const { itemType, itemId } = useParams();
  const type = itemType as ItemDetailType;
  const validType = type === 'transcript' || type === 'audio' || type === 'pdf';
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const { requestConsent } = useAIProcessingConsent();
  const [item, setItem] = useState<DetailItem | null>(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [preferences, setPreferences] = useState<LibraryPreferences>({ favorite: false, archived: false, tags: [] });
  // Segments and the playback address belong to one item: keyed by it, so a
  // late answer for the previous item never shows up on the next.
  const [segmentState, setSegmentState] = useState<{ key: string; list: MediaSegment[] } | null>(null);
  const [videoSummary, setVideoSummary] = useState<Summary | null | undefined>(undefined);
  const [audioSource, setAudioSource] = useState<{ id: string; url: string } | null>(null);
  const [automaticSummaries, setAutomaticSummaries] = useState<boolean | undefined>(undefined);
  const [showVideo, setShowVideo] = useState(false);
  const [videoStart, setVideoStart] = useState(0);
  const [dialog, setDialog] = useState<'collection' | 'rename' | 'tags' | 'summarize' | 'ask' | 'export' | null>(null);
  const playerRef = useRef<PlayerHandle | null>(null);
  const videoRef = useRef<HTMLIFrameElement | null>(null);

  const load = useCallback(async () => {
    if (!itemId || !validType) return;
    try {
      const next = type === 'transcript' ? await getTranscript(itemId) : type === 'audio' ? await getAudioTranscription(itemId) : await getPDFExtraction(itemId);
      setItem(next);
      setLoadError('');
    } catch (err) {
      setLoadError(getErrorMessage(err));
    }
  }, [itemId, type, validType]);

  const loadVideoSummary = useCallback(async () => {
    if (type !== 'transcript' || !itemId) return;
    try {
      const summaries = await getSummaries(itemId);
      setVideoSummary(summaries[0] ?? null);
    } catch {
      setVideoSummary((current) => current ?? null);
    }
  }, [itemId, type]);

  useEffect(() => {
    queueMicrotask(() => { setItem(null); setLoadError(''); setVideoSummary(undefined); setShowVideo(false); });
    void load();
    if (!itemId || !validType) return;
    getLibraryPreferences(type, itemId).then(setPreferences).catch(() => undefined);
    getProcessingPreferences().then((value) => setAutomaticSummaries(value.automatic_summaries)).catch(() => undefined);
  }, [itemId, load, type, validType]);

  const status = item?.status ?? '';
  const audio = type === 'audio' ? (item as AudioTranscription | null) : null;
  const complete = status === 'completed';

  useEffect(() => {
    if (complete && type === 'transcript') void loadVideoSummary();
  }, [complete, loadVideoSummary, type]);

  useEffect(() => {
    if (!itemId || !validType || !complete) return;
    let current = true;
    const key = `${type}:${itemId}`;
    getMediaSegments(type, itemId).then((result) => { if (current) setSegmentState({ key, list: result }); }).catch(() => { if (current) setSegmentState({ key, list: [] }); });
    return () => { current = false; };
  }, [complete, itemId, type, validType]);
  const segmentsLoaded = segmentState?.key === `${type}:${itemId}`;
  const segments = useMemo(() => (segmentsLoaded && segmentState ? segmentState.list : []), [segmentState, segmentsLoaded]);

  // The playback URL is fetched once per recording, not on every refresh of
  // the item, so background polling never resets the player.
  const playable = type === 'audio' && Boolean(item) && status !== 'pending' && audio?.audio_s3_status !== 'pending';
  const fetchAudioURL = useCallback(() => {
    if (!itemId) return;
    getAudioPlaybackUrl(itemId).then((result) => setAudioSource({ id: itemId, url: result.url })).catch(() => setAudioSource({ id: itemId, url: '' }));
  }, [itemId]);
  const currentAudio = audioSource && audioSource.id === itemId ? audioSource : null;
  const audioURL = currentAudio?.url ?? '';
  const audioUnavailable = currentAudio !== null && currentAudio.url === '';
  useEffect(() => { if (playable) fetchAudioURL(); }, [fetchAudioURL, playable]);

  const itemActive = isActive(status) || isActive(audio?.summary_status) || isActive(audio?.formatting_status);
  useBackoffRefresh(itemActive, load);
  useBackoffRefresh(type === 'transcript' && isActive(videoSummary?.status), loadVideoSummary);

  const view = useMemo(() => describe(type, item), [item, type]);

  const openCitation = useCallback((citation: Citation) => {
    if (!itemId) return;
    if (citation.item_id !== itemId || citation.item_type !== type) {
      const params = new URLSearchParams();
      if (typeof citation.start_ms === 'number') params.set('t', String(Math.floor(citation.start_ms / 1000)));
      if (typeof citation.page_number === 'number') params.set('page', String(citation.page_number));
      navigate(`/app/items/${citation.item_type}/${citation.item_id}${params.toString() ? `?${params}` : ''}`);
      return;
    }
    if (typeof citation.start_ms === 'number') {
      const seconds = citation.start_ms / 1000;
      if (type === 'audio') {
        playerRef.current?.seek(seconds);
        document.getElementById('player')?.scrollIntoView({ block: 'nearest' });
      }
      if (type === 'transcript') {
        if (!showVideo) { setVideoStart(Math.floor(seconds)); setShowVideo(true); }
        else videoRef.current?.contentWindow?.postMessage(JSON.stringify({ event: 'command', func: 'seekTo', args: [seconds, true] }), 'https://www.youtube-nocookie.com');
        document.getElementById('player')?.scrollIntoView({ block: 'nearest' });
      }
      return;
    }
    const target = typeof citation.page_number === 'number' ? document.querySelector(`[data-page="${citation.page_number}"]`) : document.getElementById(`segment-${citation.segment_id}`);
    target?.scrollIntoView({ block: 'start' });
  }, [itemId, navigate, showVideo, type]);

  // A deep link (?t= or ?page=) lands once the item is ready and the thing it
  // points at (player, video, page text) exists. It is used up once per item and
  // place, so a second citation to another spot is followed too.
  const consumedLink = useRef('');
  const landingRef = useRef<Citation | null>(null);
  const isCurrentItem = Boolean(item && item.id === itemId);
  const hasVideo = type === 'transcript' && Boolean((item as Transcript | null)?.youtube_id);
  useEffect(() => {
    const link = parseDeepLink(searchParams, type, itemId);
    if (!link) { consumedLink.current = ''; return; }
    if (consumedLink.current === link.key || !item || !isCurrentItem || !complete) return;
    const action = deepLinkAction(link, {
      type,
      audioPlayerReady: playerRef.current !== null,
      audioUnavailable,
      hasVideo,
      segmentsLoaded,
    });
    if (action === 'wait') return;
    consumedLink.current = link.key;
    // Clearing the address changes the location, and the router resets scroll
    // when it does. Land after that, in the effect below, not before it.
    if (action === 'go' && link.target) {
      landingRef.current = 'seconds' in link.target
        ? { segment_id: 'link', item_type: type, item_id: item.id, start_ms: link.target.seconds * 1000 }
        : { segment_id: 'link', item_type: type, item_id: item.id, page_number: link.target.page };
    }
    setSearchParams({}, { replace: true });
  }, [audioURL, audioUnavailable, complete, hasVideo, isCurrentItem, item, itemId, searchParams, segmentsLoaded, setSearchParams, type]);

  useEffect(() => {
    if (!landingRef.current || searchParams.has('t') || searchParams.has('page')) return;
    const citation = landingRef.current;
    landingRef.current = null;
    openCitation(citation);
  }, [openCitation, searchParams]);

  if (!validType) return <Navigate to={APP_ROUTES.library} replace />;

  const run = async (key: string, action: () => Promise<void>, options: { ai?: boolean } = {}) => {
    if (options.ai && !(await requestConsent())) return;
    setBusy(key);
    setError('');
    setMessage('');
    try {
      await action();
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setBusy(null);
    }
  };

  const goBack = () => {
    // Back keeps the Library's search, filters and scroll position.
    const index = (window.history.state as { idx?: number } | null)?.idx ?? 0;
    if (index > 0) navigate(-1);
    else navigate(APP_ROUTES.library);
  };

  if (!item) {
    return (
      <div className="mx-auto max-w-2xl">
        <BackLink onBack={goBack} />
        {loadError ? (
          <div className="py-12">
            <p className="text-title">This item could not be opened</p>
            <p className="mt-2 text-callout text-text-secondary">{loadError}</p>
            <div className="mt-4 flex gap-2"><Button onClick={() => void load()} icon={<RefreshCw className="h-4 w-4" />}>Try again</Button><ButtonLink to={APP_ROUTES.library} variant="plain">Library</ButtonLink></div>
          </div>
        ) : (
          <div className="mt-6 space-y-3" role="status" aria-label="Loading">
            <div className="h-8 w-3/4 rounded-sm bg-fill" />
            <div className="h-4 w-1/3 rounded-sm bg-fill" />
            <div className="mt-8 h-4 w-full rounded-sm bg-fill" />
            <div className="h-4 w-11/12 rounded-sm bg-fill" />
          </div>
        )}
      </div>
    );
  }

  const summary: SummaryView | null = type === 'audio' && audio
    ? {
      status: audio.summary_status,
      text: audio.summary_text || '',
      keyPoints: audio.key_points || [],
      actionItems: audio.action_items || [],
      decisions: audio.decisions || [],
      evidence: audio.summary_evidence,
      errorMessage: audio.summary_error_message,
      reportTarget: { type: 'audio_summary', id: audio.id },
    }
    : type === 'transcript' && videoSummary !== undefined
      ? {
        status: videoSummary ? videoSummary.status : 'none',
        text: videoSummary?.summary_text || '',
        keyPoints: parseKeyPoints(videoSummary?.key_points),
        actionItems: [],
        decisions: [],
        evidence: videoSummary?.evidence,
        errorMessage: videoSummary?.error_message,
        reportTarget: videoSummary ? { type: 'transcript_summary', id: videoSummary.id } : undefined,
      }
      : null;

  const summarize = (contentType?: AudioContentType) => run('summary', async () => {
    if (type === 'audio' && audio) {
      setItem(await summarizeAudio(audio.id, { content_type: contentType || audio.content_type || 'general', length: 'medium' }));
    } else if (type === 'transcript') {
      await createSummary(item.id, { length: 'medium', style: 'bullet' });
      await loadVideoSummary();
    }
    setDialog(null);
  }, { ai: true });

  const remove = () => {
    if (!window.confirm(`Delete “${view.title}”? This removes the transcript, summary and conversation.`)) return;
    void run('delete', async () => {
      if (type === 'transcript') await deleteTranscript(item.id);
      else if (type === 'audio') await deleteAudioTranscription(item.id);
      else await deletePDFExtraction(item.id);
      notifyLibraryActivityChanged();
      navigate(APP_ROUTES.library, { replace: true });
    });
  };

  const savePreferences = (changes: Partial<LibraryPreferences>) => run('preferences', async () => {
    setPreferences(await updateLibraryPreferences(type, item.id, changes));
  });

  const copyText = async () => {
    try {
      await navigator.clipboard.writeText(view.text);
      setMessage('Copied the text.');
    } catch {
      setError('The browser blocked the clipboard. Allow clipboard access and try again.');
    }
  };

  const exportFormats = exportFormatsFor(type);
  const exportItem = (format: ExportFormat) => run('export', async () => {
    const blob = type === 'transcript' ? await downloadExport(item.id, format)
      : type === 'audio' ? await downloadAudioExport(item.id, format as AudioExportFormat)
        : new Blob([view.text], { type: 'text/plain;charset=utf-8' });
    downloadBlob(blob, `${safeFilename(view.title)}.${format}`);
    setDialog(null);
  });

  const stopProcessing = () => void run('cancel', async () => {
    if (!audio) return;
    setItem(await cancelAudioTranscription(audio.id));
    notifyLibraryActivityChanged();
  });

  const formatTranscript = () => void run('format', async () => {
    if (audio) setItem(await formatAudioTranscript(audio.id));
  }, { ai: true });

  const menu: MenuItem[] = [
    ...(view.text ? [{ label: 'Copy text', icon: <Copy />, onSelect: () => void copyText() }, { label: exportFormats.length > 1 ? 'Export…' : 'Export as text', icon: <Download />, onSelect: () => (exportFormats.length > 1 ? setDialog('export') : void exportItem(exportFormats[0].format)) }] : []),
    { label: preferences.favorite ? 'Unstar' : 'Star', icon: <Star />, onSelect: () => void savePreferences({ favorite: !preferences.favorite }) },
    { label: 'Edit tags', icon: <Tag />, onSelect: () => setDialog('tags') },
    ...(type === 'audio' ? [{ label: 'Rename', icon: <Pencil />, onSelect: () => setDialog('rename') }] : []),
    ...(view.sourceURL ? [{ label: 'Open the source', icon: <ExternalLink />, onSelect: () => window.open(view.sourceURL, '_blank', 'noopener,noreferrer') }] : []),
    ...(complete && type !== 'pdf' && summary && !isActive(summary.status)
      ? [{ label: summary.status === 'completed' ? 'Summarize again' : 'Summarize', icon: <RotateCcw />, onSelect: () => (type === 'audio' ? setDialog('summarize') : void summarize()) }]
      : []),
    ...(audio && complete && (audio.formatting_status === 'none' || audio.formatting_status === 'failed')
      ? [{ label: 'Tidy into paragraphs', icon: <AlignLeft />, onSelect: formatTranscript }]
      : []),
    ...(audio && isActive(status) ? [{ label: 'Stop processing', icon: <Square />, onSelect: stopProcessing }] : []),
    { label: preferences.archived ? 'Move out of archive' : 'Archive', icon: <Archive />, onSelect: () => void savePreferences({ archived: !preferences.archived }) },
    { kind: 'separator' },
    { label: 'Delete', icon: <Trash2 />, tone: 'danger', onSelect: remove },
  ];

  const askPlaceholder = type === 'audio' ? 'Ask about this recording' : type === 'transcript' ? 'Ask about this video' : 'Ask about this document';

  return (
    <div className="mx-auto max-w-5xl pb-28 lg:grid lg:grid-cols-[minmax(0,1fr)_20rem] lg:gap-12 lg:pb-10">
      <article className="min-w-0 lg:max-w-[42rem]">
        <div className="flex items-center gap-1">
          <BackLink onBack={goBack} />
          <div className="flex-1" />
          <button type="button" onClick={() => setDialog('collection')} aria-label="Add to collection" title="Add to collection" className="pressable inline-flex h-11 w-11 items-center justify-center rounded-full text-accent hover:bg-fill"><FolderPlus className="h-[22px] w-[22px]" /></button>
          <Menu label="More actions" trigger={<MoreHorizontal className="h-[22px] w-[22px]" />} items={menu} />
        </div>

        <h1 className="mt-2 break-words text-title">{view.title}</h1>
        <p className="mt-1.5 flex flex-wrap items-center gap-x-1.5 text-callout text-text-secondary">
          {[formatItemDate(view.createdAt), view.length, view.byline].filter(Boolean).join(' · ')}
          {preferences.favorite && <Star className="h-3.5 w-3.5 fill-current" aria-label="Starred" />}
          {preferences.archived && <span>· Archived</span>}
        </p>
        {preferences.tags.length > 0 && <p className="mt-1 text-meta text-text-secondary">{preferences.tags.map((tag) => `#${tag}`).join('  ')}</p>}

        {type === 'audio' && audioURL && (
          <div id="player"><AudioPlayer src={audioURL} fallbackDuration={audio?.duration} handleRef={playerRef} onExpired={fetchAudioURL} /></div>
        )}
        {type === 'transcript' && complete && (item as Transcript).youtube_id && (
          <div id="player" className="mt-4">
            {showVideo ? (
              <div className="overflow-hidden rounded-lg bg-[#000]">
                <iframe ref={videoRef} className="aspect-video w-full" src={`https://www.youtube-nocookie.com/embed/${(item as Transcript).youtube_id}?enablejsapi=1&playsinline=1&rel=0&autoplay=1&start=${videoStart}`} title={`Video: ${view.title}`} allow="autoplay; encrypted-media; picture-in-picture" allowFullScreen />
              </div>
            ) : (
              <Button variant="plain" className="-ml-4" onClick={() => setShowVideo(true)} icon={<Play className="h-4 w-4 fill-current" />}>Play the video</Button>
            )}
          </div>
        )}

        {message && <div className="mt-4"><Notice tone="success">{message}</Notice></div>}
        {error && <div className="mt-4"><Notice tone="error">{error}</Notice></div>}

        {isActive(status) && <ProgressNote label={view.progressLabel} progress={view.progress} onStop={audio ? stopProcessing : undefined} stopping={busy === 'cancel'} />}

        {status === 'failed' && (
          <FailedNote
            type={type}
            message={view.errorMessage}
            busy={busy === 'retry'}
            onRetry={type === 'pdf' ? undefined : () => void run('retry', async () => {
              if (type === 'audio') {
                setItem(await retryAudioTranscription(item.id));
                notifyLibraryActivityChanged();
              } else {
                const fresh = await addVideoLink((item as Transcript).youtube_url);
                navigate(`/app/items/transcript/${fresh.id}`, { replace: true });
              }
            }, { ai: type === 'audio' })}
            onDelete={remove}
          />
        )}

        {audio?.quality_warning && (
          <div className="mt-4"><Notice>
            <span className="font-semibold">Part of this recording could not be transcribed.</span> {audio.quality_warning}
            {(audio.omitted_ranges || []).length > 0 && <span className="mt-1 block text-meta text-text-secondary tabular">Missing: {audio.omitted_ranges?.map((range) => `${formatClock(range.start)}–${formatClock(range.end)}`).join(', ')}</span>}
          </Notice></div>
        )}

        {complete && summary && type !== 'pdf' && (
          <SummarySection
            summary={summary}
            onSummarize={() => (type === 'audio' && summary.status !== 'none' ? setDialog('summarize') : void summarize())}
            busy={busy === 'summary'}
            onCitationClick={openCitation}
            automaticSummaries={type === 'audio' ? automaticSummaries : undefined}
          />
        )}

        {complete && (
          <TranscriptSection
            title={type === 'pdf' ? 'Text' : 'Transcript'}
            text={view.text}
            originalText={audio?.transcript_text}
            segments={segments}
            onCitationClick={openCitation}
            formatting={audio ? { status: audio.formatting_status, error: audio.formatting_error_message } : undefined}
            onFormat={audio ? formatTranscript : undefined}
            formatBusy={busy === 'format'}
          />
        )}
      </article>

      {complete && (
        <>
          {/* Desktop: the conversation sits beside the reading column. */}
          <aside className="hidden lg:block" aria-labelledby="ask-heading">
            <div className="sticky top-20 flex h-[calc(100dvh-6.5rem)] flex-col pt-14">
              <h2 id="ask-heading" className="mb-3 text-heading">Ask</h2>
              <ChatPanel itemId={item.id} itemType={type} placeholder={askPlaceholder} onCitationClick={openCitation} fill />
            </div>
          </aside>
          {/* Phones: a quiet bar at the thumb opens the conversation. */}
          <div className="fixed inset-x-0 bottom-0 z-20 border-t border-separator bg-bar px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-2.5 backdrop-blur-xl lg:hidden">
            <button type="button" onClick={() => setDialog('ask')} className="pressable flex min-h-11 w-full items-center gap-2 rounded-full border border-separator bg-surface pl-4 pr-1.5 text-left text-body text-text-secondary">
              <MessageSquare className="h-[18px] w-[18px]" aria-hidden="true" />
              <span className="flex-1">{askPlaceholder}</span>
            </button>
          </div>
          <Dialog open={dialog === 'ask'} onClose={() => setDialog(null)} title="Ask" size="lg">
            <div className="flex h-[min(70dvh,640px)] flex-col"><ChatPanel itemId={item.id} itemType={type} placeholder={askPlaceholder} onCitationClick={(citation) => { setDialog(null); openCitation(citation); }} autoFocus fill /></div>
          </Dialog>
        </>
      )}

      <AddToCollectionModal open={dialog === 'collection'} onClose={() => setDialog(null)} itemType={type} itemId={item.id} itemTitle={view.title} />
      {audio && <RenameDialog open={dialog === 'rename'} name={audio.original_name} onClose={() => setDialog(null)} onSave={(name) => void run('rename', async () => { setItem(await renameAudioTranscription(audio.id, name)); setDialog(null); })} busy={busy === 'rename'} />}
      <ExportDialog open={dialog === 'export'} formats={exportFormats} onClose={() => setDialog(null)} onChoose={(format) => void exportItem(format)} busy={busy === 'export'} />
      <TagsDialog open={dialog === 'tags'} tags={preferences.tags} onClose={() => setDialog(null)} onSave={(tags) => void savePreferences({ tags })} busy={busy === 'preferences'} />
      {audio && <SummarizeDialog open={dialog === 'summarize'} initial={audio.content_type || 'general'} onClose={() => setDialog(null)} onSubmit={(contentType) => void summarize(contentType)} busy={busy === 'summary'} />}
    </div>
  );
}

function BackLink({ onBack }: { onBack: () => void }) {
  return (
    <Link to={APP_ROUTES.library} onClick={(event) => { event.preventDefault(); onBack(); }} className="pressable -ml-2 inline-flex min-h-11 items-center gap-0.5 rounded-md pr-3 text-body text-accent hover:bg-fill">
      <ChevronLeft className="h-6 w-6" aria-hidden="true" />Library
    </Link>
  );
}

function ProgressNote({ label, progress, onStop, stopping }: { label: string; progress: number; onStop?: () => void; stopping: boolean }) {
  return (
    <div className="mt-6" role="status" aria-live="polite">
      <p className="flex items-center gap-2 text-body font-medium"><Loader2 className="h-4 w-4 animate-spin text-text-secondary" aria-hidden="true" />{label}{progress > 0 && <span className="text-text-secondary tabular">{progress}%</span>}</p>
      {progress > 0 && <div className="mt-3 h-1 overflow-hidden rounded-full bg-separator"><div className="h-full rounded-full bg-accent-fill transition-[width] duration-500" style={{ width: `${Math.min(progress, 100)}%` }} /></div>}
      <p className="mt-2 text-callout text-text-secondary">This keeps going if you leave. The transcript and summary appear here by themselves.</p>
      {onStop && <Button variant="plain" className="-ml-4 mt-1" onClick={onStop} busy={stopping}>Stop processing</Button>}
    </div>
  );
}

function FailedNote({ type, message, busy, onRetry, onDelete }: { type: ItemDetailType; message: string; busy: boolean; onRetry?: () => void; onDelete: () => void }) {
  const copy = type === 'audio'
    ? 'The recording is saved, so trying again does not need the file.'
    : type === 'transcript'
      ? 'Trying again starts a new attempt for the same link. This one stays until you delete it.'
      : 'A PDF cannot be retried from here. If it is a scan, it has no text to read; otherwise add the file again.';
  return (
    <div className="mt-6 rounded-lg border border-separator bg-surface p-4" role="alert">
      <p className="flex items-start gap-2 text-body font-semibold"><AlertCircle className="mt-0.5 h-[18px] w-[18px] shrink-0 text-text-secondary" aria-hidden="true" />{type === 'audio' ? 'Transcription failed' : type === 'transcript' ? 'The transcript could not be fetched' : 'This PDF could not be read'}</p>
      {message && <p className="mt-1 text-callout">{message}</p>}
      {/* The server's message for recordings already says the audio is kept. */}
      {(type !== 'audio' || !message) && <p className="mt-1 text-callout text-text-secondary">{copy}</p>}
      <div className="mt-3 flex flex-wrap gap-2">
        {onRetry ? <Button variant="primary" onClick={onRetry} busy={busy} icon={<RefreshCw className="h-4 w-4" />}>Try again</Button> : <ButtonLink to={`${APP_ROUTES.add}?source=file`} variant="primary">Add a file</ButtonLink>}
        <Button variant="danger-plain" onClick={onDelete} icon={<Trash2 className="h-4 w-4" />}>Delete</Button>
      </div>
    </div>
  );
}

type AudioExportFormat = 'txt' | 'md' | 'json';

/** The formats the server offers for each kind of item. A PDF's text is saved as it is shown. */
function exportFormatsFor(type: ItemDetailType): { format: ExportFormat; label: string; hint: string }[] {
  const md = { format: 'md' as const, label: 'Markdown', hint: '.md · headings and paragraphs' };
  const txt = { format: 'txt' as const, label: 'Plain text', hint: '.txt · just the words' };
  const json = { format: 'json' as const, label: 'JSON', hint: '.json · everything, for other software' };
  if (type === 'transcript') return [md, txt, { format: 'srt', label: 'Subtitles', hint: '.srt · timed captions' }, json];
  if (type === 'audio') return [md, txt, json];
  return [{ ...txt, hint: '.txt · the extracted text' }];
}

function ExportDialog({ open, formats, onClose, onChoose, busy }: { open: boolean; formats: { format: ExportFormat; label: string; hint: string }[]; onClose: () => void; onChoose: (format: ExportFormat) => void; busy: boolean }) {
  return (
    <Dialog open={open} onClose={onClose} title="Export">
      <ul className="divide-y divide-separator">
        {formats.map((option) => (
          <li key={option.format}>
            <button type="button" disabled={busy} onClick={() => onChoose(option.format)} className="pressable flex min-h-14 w-full items-center gap-3 rounded-sm px-1 py-2 text-left hover:bg-fill disabled:opacity-40">
              <Download className="h-[18px] w-[18px] shrink-0 text-text-secondary" aria-hidden="true" />
              <span className="min-w-0 flex-1"><span className="block text-body">{option.label}</span><span className="block text-meta text-text-secondary">{option.hint}</span></span>
            </button>
          </li>
        ))}
      </ul>
    </Dialog>
  );
}

function RenameDialog({ open, name, onClose, onSave, busy }: { open: boolean; name: string; onClose: () => void; onSave: (name: string) => void; busy: boolean }) {
  const [value, setValue] = useState(name);
  useEffect(() => { if (open) queueMicrotask(() => setValue(name)); }, [name, open]);
  const save = () => { if (value.trim() && value.trim() !== name) onSave(value.trim()); else onClose(); };
  return (
    <Dialog open={open} onClose={onClose} title="Rename" footer={<div className="flex justify-end gap-2"><Button onClick={onClose}>Cancel</Button><Button variant="primary" busy={busy} disabled={!value.trim()} onClick={save}>Save</Button></div>}>
      <form onSubmit={(event) => { event.preventDefault(); save(); }}>
        <Input value={value} onChange={(event) => setValue(event.target.value)} aria-label="Title" maxLength={255} autoFocus />
      </form>
      <p className="mt-2 text-meta text-text-secondary">A title you set is never replaced by an automatic one.</p>
    </Dialog>
  );
}

function TagsDialog({ open, tags, onClose, onSave, busy }: { open: boolean; tags: string[]; onClose: () => void; onSave: (tags: string[]) => void; busy: boolean }) {
  const [input, setInput] = useState('');
  const add = () => {
    const value = input.trim();
    if (!value || tags.some((tag) => tag.toLocaleLowerCase() === value.toLocaleLowerCase())) return;
    onSave([...tags, value]);
    setInput('');
  };
  return (
    <Dialog open={open} onClose={onClose} title="Tags" footer={<Button variant="primary" block onClick={onClose}>Done</Button>}>
      {tags.length === 0 ? <p className="text-callout text-text-secondary">Add a client, project or topic to find this later.</p> : (
        <ul className="flex flex-wrap gap-1.5">
          {tags.map((tag) => (
            <li key={tag} className="inline-flex items-center rounded-full bg-fill pl-3 text-callout">
              {tag}
              <button type="button" onClick={() => onSave(tags.filter((value) => value !== tag))} disabled={busy} aria-label={`Remove ${tag}`} className="inline-flex h-11 w-10 items-center justify-center text-text-secondary"><X className="h-4 w-4" /></button>
            </li>
          ))}
        </ul>
      )}
      <form onSubmit={(event) => { event.preventDefault(); add(); }} className="mt-4 flex gap-2">
        <Input value={input} onChange={(event) => setInput(event.target.value)} placeholder="New tag" aria-label="New tag" maxLength={40} />
        <Button type="submit" busy={busy} disabled={!input.trim()}>Add</Button>
      </form>
    </Dialog>
  );
}

function SummarizeDialog({ open, initial, onClose, onSubmit, busy }: { open: boolean; initial: AudioContentType; onClose: () => void; onSubmit: (type: AudioContentType) => void; busy: boolean }) {
  const [value, setValue] = useState<AudioContentType>(initial);
  return (
    <Dialog open={open} onClose={onClose} title="Summarize" footer={<div className="flex justify-end gap-2"><Button onClick={onClose}>Cancel</Button><Button variant="primary" busy={busy} onClick={() => onSubmit(value)}>Summarize</Button></div>}>
      <p className="text-callout text-text-secondary">What kind of recording is this? The summary looks for what matters in each.</p>
      <div className="mt-3 grid grid-cols-2 gap-2" role="radiogroup" aria-label="Kind of recording">
        {CONTENT_TYPES.map((option) => (
          <button key={option.value} type="button" role="radio" aria-checked={value === option.value} onClick={() => setValue(option.value)} className={`pressable min-h-11 rounded-md border px-3 text-left text-callout ${value === option.value ? 'border-accent bg-accent-tint font-semibold text-accent' : 'border-separator'}`}>
            {option.label}
          </button>
        ))}
      </div>
    </Dialog>
  );
}

function describe(type: ItemDetailType, item: DetailItem | null) {
  const empty = { title: '', byline: '', length: '', text: '', createdAt: '', sourceURL: '', errorMessage: '', progress: 0, progressLabel: '' };
  if (!item) return empty;
  if (type === 'transcript') {
    const value = item as Transcript;
    return {
      ...empty,
      title: value.title || (value.status === 'failed' ? 'Video link' : 'Getting the video…'),
      byline: value.channel_name || '',
      length: formatDuration(value.duration),
      text: value.transcript_text || '',
      createdAt: value.created_at,
      sourceURL: value.youtube_url,
      errorMessage: value.error_message || '',
      progressLabel: value.status === 'pending' ? 'Waiting to fetch the transcript' : 'Fetching the transcript',
    };
  }
  if (type === 'audio') {
    const value = item as AudioTranscription;
    const readable = value.formatting_status === 'completed' && value.formatted_transcript_text?.trim() ? value.formatted_transcript_text : value.transcript_text;
    return {
      ...empty,
      title: displayTitle(value.original_name || '') || 'Untitled recording',
      length: formatDuration(value.duration),
      text: readable || '',
      createdAt: value.created_at,
      errorMessage: value.error_message || '',
      progress: value.processing_progress || 0,
      progressLabel: audioStage(value.processing_stage, value.status),
    };
  }
  const value = item as PDFExtraction;
  return {
    ...empty,
    title: value.original_name || 'Untitled PDF',
    length: value.page_count ? pluralize(value.page_count, 'page') : '',
    text: value.text_content || '',
    createdAt: value.created_at,
    errorMessage: value.error_message || '',
    progressLabel: 'Reading the PDF',
  };
}

function audioStage(stage: string | undefined, status: string) {
  switch (stage) {
    case 'downloading': return 'Getting the audio ready';
    case 'transcoding': return 'Preparing the recording';
    case 'chunking': return 'Splitting a long recording';
    case 'transcribing': return 'Transcribing';
    case 'stitching': return 'Putting the transcript together';
    default: return status === 'pending' ? 'Waiting to transcribe' : 'Transcribing';
  }
}

function safeFilename(value: string) {
  return value.replace(/\.[^.]+$/, '').replace(/[^a-z0-9-_]+/gi, '_').replace(/^_+|_+$/g, '') || 'media-tools-export';
}
