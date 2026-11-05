import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { AlertCircle, AudioLines, Download, FileText, Link2, MoreHorizontal, Play, Trash2 } from 'lucide-react';
import { getErrorMessage, listLibraryItems, retryAudioTranscription, type LibraryItem } from '../lib/api';
import { APP_ROUTES } from '../lib/appRoutes';
import { downloadBlob } from '../lib/download';
import { formatClock, formatTimeOfDay } from '../lib/format';
import { displayTitle, itemAttention, itemDetailPath, itemRowView } from '../lib/library';
import { notifyLibraryActivityChanged } from '../lib/libraryActivityEvents';
import { isAbortError, recordingFileName, uploadAudio } from '../lib/mediaUpload';
import { greeting, limitNeedsYou, selectNeedsYou, type NeedsYouEntry } from '../lib/needsYou';
import { createOperationSlot } from '../lib/operation';
import { deleteRecordingDraft, listRecordingDrafts, recoverInterruptedRecordings, type PendingRecording } from '../lib/recordingStore';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { useLibraryActivity } from '../contexts/useLibraryActivity';
import { RecordCard } from '../components/home/RecordCard';
import { AttentionLabel, CollectionTag } from '../components/library/ItemRow';
import { ProcessingLink } from '../components/ProcessingLink';
import { Button, ButtonLink } from '../components/ui/Button';
import { Notice } from '../components/ui/Field';
import { Menu } from '../components/ui/Menu';

const RECENT = 5;
const FAILED_PAGE = 50;
const NEEDS_YOU_SHOWN = 5;

const SHORTCUTS = [
  { label: 'Import', icon: AudioLines, to: `${APP_ROUTES.add}?source=file` },
  { label: 'Link', icon: Link2, to: `${APP_ROUTES.add}?source=link` },
  { label: 'PDF', icon: FileText, to: `${APP_ROUTES.add}?source=pdf` },
];

const FROM_HOME = { from: 'Home' };

type Upload = { id: string; progress: number | null };

/** Where to start: record, add something, deal with what needs you, pick up what is recent. */
export function HomePage() {
  const navigate = useNavigate();
  const { activeItems } = useLibraryActivity();
  const { requestConsent } = useAIProcessingConsent();
  const [recent, setRecent] = useState<LibraryItem[] | null>(null);
  const [failed, setFailed] = useState<LibraryItem[]>([]);
  const [recordings, setRecordings] = useState<PendingRecording[]>([]);
  const [error, setError] = useState('');
  const [refreshToken, setRefreshToken] = useState(0);
  const [upload, setUpload] = useState<Upload | null>(null);
  const [retrying, setRetrying] = useState<string | null>(null);
  const [operations] = useState(createOperationSlot);
  const now = useMemo(() => new Date(), []);

  // Leaving stops an upload from here; the recording stays saved on this device.
  const cancelOperation = operations.cancel;
  useEffect(() => cancelOperation, [cancelOperation]);

  const refreshRecordings = useCallback(async () => {
    try { setRecordings(await listRecordingDrafts()); } catch { /* Storage blocked: nothing to show. */ }
  }, []);

  useEffect(() => {
    void recoverInterruptedRecordings().catch(() => 0).then(() => refreshRecordings());
  }, [refreshRecordings]);

  // Refresh when something finishes or starts processing.
  const activeSignature = activeItems.map((item) => `${item.item_type}:${item.id}:${item.status}`).sort().join('|');

  useEffect(() => {
    let current = true;
    listLibraryItems({ per_page: RECENT })
      .then((result) => { if (current) { setRecent(result.data); setError(''); } })
      .catch((err: unknown) => { if (current) setError(getErrorMessage(err)); });
    listLibraryItems({ status: 'failed', per_page: FAILED_PAGE, sort_dir: 'desc' })
      .then((result) => { if (current) setFailed(result.data); })
      .catch(() => undefined);
    return () => { current = false; };
  }, [activeSignature, refreshToken]);

  const needsYou = useMemo(() => selectNeedsYou(failed, recordings, now.getTime()), [failed, now, recordings]);

  const transcribe = async (recording: PendingRecording) => {
    setError('');
    const operation = operations.begin();
    if (!(await requestConsent()) || !operation.live()) return;
    setUpload({ id: recording.id, progress: 0 });
    try {
      const file = new File([recording.blob], recordingFileName(recording.mimeType, recording.createdAt), { type: recording.blob.type || recording.mimeType });
      const transcription = await uploadAudio(file, (percent) => {
        if (operation.live()) setUpload((value) => value && { ...value, progress: percent < 0 ? null : percent });
      }, operation.signal);
      await deleteRecordingDraft(recording.id).catch(() => undefined);
      if (operation.live()) navigate(itemDetailPath('audio', transcription.id));
    } catch (err) {
      if (!operation.live() || isAbortError(err)) return;
      setUpload(null);
      setError(`The upload did not finish: ${getErrorMessage(err)} The recording is still saved on this device.`);
    }
  };

  const removeRecording = async (recording: PendingRecording) => {
    if (!window.confirm('Delete this recording from this device? It has not been uploaded.')) return;
    await deleteRecordingDraft(recording.id).catch(() => undefined);
    await refreshRecordings();
  };

  const retry = async (item: LibraryItem) => {
    if (!(await requestConsent())) return;
    setRetrying(item.id);
    setError('');
    try {
      await retryAudioTranscription(item.id);
      notifyLibraryActivityChanged();
      setRefreshToken((value) => value + 1);
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setRetrying(null);
    }
  };

  const date = new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'short', day: 'numeric' }).format(now);
  const { shown, hiddenFailures } = limitNeedsYou(needsYou, NEEDS_YOU_SHOWN);

  return (
    <div className="mx-auto max-w-5xl">
      <header className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-meta font-semibold text-text-secondary">{date}</p>
          <h1 className="text-large-title">{greeting(now.getHours())}</h1>
        </div>
        <ProcessingLink className="-mr-2 md:hidden" />
      </header>

      {error && <div className="mt-3"><Notice tone="error" action={<Button variant="plain" onClick={() => setRefreshToken((value) => value + 1)}>Try again</Button>}>{error}</Notice></div>}

      <div className="mt-3.5 md:mt-5 lg:grid lg:grid-cols-[minmax(0,1.05fr)_minmax(0,1fr)] lg:items-start lg:gap-10">
        <div className="min-w-0">
          <RecordCard to={`${APP_ROUTES.add}?record=1`} hint="Start talking. The transcript and summary follow." />
          <div className="mt-2.5 grid grid-cols-3 gap-2.5">
            {SHORTCUTS.map((shortcut) => (
              <Link key={shortcut.label} to={shortcut.to} className="pressable flex min-h-[4.5rem] flex-col items-center justify-center gap-1 rounded-lg bg-surface text-meta font-semibold hover:bg-fill">
                <shortcut.icon className="h-[22px] w-[22px] text-accent-text" aria-hidden="true" />{shortcut.label}
              </Link>
            ))}
          </div>

          {shown.length > 0 && (
            <section aria-labelledby="needs-you" className="mt-5">
              <h2 id="needs-you" className="mb-2 text-meta font-semibold text-text-secondary">Needs you</h2>
              <ul className="space-y-2">
                {shown.map((entry) => (
                  <NeedsYouRow key={entry.key} entry={entry} upload={upload} retrying={retrying} onTranscribe={(recording) => void transcribe(recording)} onDelete={(recording) => void removeRecording(recording)} onRetry={(item) => void retry(item)} />
                ))}
              </ul>
              {hiddenFailures > 0 && <Link to={`${APP_ROUTES.library}?status=failed`} className="inline-flex min-h-11 items-center text-callout font-semibold text-accent-text">See {hiddenFailures.toLocaleString()} more failed</Link>}
            </section>
          )}
        </div>

        {!(recent === null && error) && <section aria-labelledby="recent" className="mt-5 min-w-0 lg:mt-0">
          <div className="mb-2 flex min-h-5 items-center justify-between">
            <h2 id="recent" className="text-meta font-semibold text-text-secondary">Recent</h2>
            {recent !== null && recent.length > 0 && <Link to={APP_ROUTES.library} className="-my-3 inline-flex min-h-11 items-center px-1 text-meta font-semibold text-accent-text">See all</Link>}
          </div>
          {recent === null ? (
            <div className="space-y-2" role="status" aria-label="Loading recent items">{Array.from({ length: 3 }, (_, index) => <div key={index} className="h-[5.5rem] rounded-lg bg-fill" />)}</div>
          ) : recent.length === 0 ? (
            <div className="rounded-lg bg-surface p-5">
              <p className="text-subheading">Nothing here yet</p>
              <p className="mt-1 text-callout text-text-secondary">Record a thought, paste a video link, or add a PDF. The transcript and summary land here.</p>
            </div>
          ) : (
            <ul className="space-y-2">{recent.map((item) => <RecentCard key={`${item.item_type}-${item.id}`} item={item} now={now} />)}</ul>
          )}
        </section>}
      </div>
    </div>
  );
}

function RecentCard({ item, now }: { item: LibraryItem; now: Date }) {
  const view = itemRowView(item, now);
  const attention = itemAttention(item);
  const when = view.day === 'Today' ? formatTimeOfDay(item.created_at) : view.day;
  return (
    <li>
      <Link to={itemDetailPath(item.item_type, item.id)} state={FROM_HOME} className="pressable block rounded-lg bg-surface p-3.5 hover:bg-fill">
        <span className="flex items-baseline justify-between gap-3">
          <span className="min-w-0 truncate font-display text-[1.0625rem] font-bold leading-6">{displayTitle(item.title)}</span>
          <span className="shrink-0 text-meta text-text-secondary">{when}</span>
        </span>
        {view.excerpt && <span className="mt-0.5 line-clamp-2 text-excerpt text-text-secondary">{view.excerpt}</span>}
        <span className="mt-1 flex min-w-0 items-center gap-1.5 text-meta text-text-secondary">
          {attention ? <AttentionLabel item={item} /> : (
            <>
              {view.collection && <CollectionTag collection={view.collection} />}
              {view.collection && (view.source || view.length) && <span aria-hidden="true">·</span>}
              {view.source && <span className="truncate">{view.source}</span>}
              {view.source && view.length && <span aria-hidden="true">·</span>}
              {view.length && <span className="shrink-0 font-mono">{view.length}</span>}
            </>
          )}
        </span>
      </Link>
    </li>
  );
}

function NeedsYouRow({ entry, upload, retrying, onTranscribe, onDelete, onRetry }: {
  entry: NeedsYouEntry;
  upload: Upload | null;
  retrying: string | null;
  onTranscribe: (recording: PendingRecording) => void;
  onDelete: (recording: PendingRecording) => void;
  onRetry: (item: LibraryItem) => void;
}) {
  const navigate = useNavigate();
  if (entry.kind === 'failed') {
    const { item } = entry;
    const path = itemDetailPath(item.item_type, item.id);
    return (
      <AttentionRow title={<Link to={path} state={FROM_HOME} className="underline-offset-2 hover:underline">{displayTitle(item.title)}</Link>} meta={itemAttention(item)?.label ?? 'Failed'}>
        {item.item_type === 'audio'
          ? <Button variant="primary" className="rounded-full" busy={retrying === item.id} onClick={() => onRetry(item)}>Try again</Button>
          : <ButtonLink to={path} state={FROM_HOME} className="rounded-full bg-surface-2">Open</ButtonLink>}
      </AttentionRow>
    );
  }
  const { recording } = entry;
  const uploading = upload?.id === recording.id;
  const day = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(recording.createdAt);
  const length = recording.durationSeconds ? `${formatClock(recording.durationSeconds)}, ` : '';
  const meta = uploading
    ? `Uploading${upload?.progress !== null && upload?.progress !== undefined ? ` ${upload.progress}%` : ''}. Keep this page open.`
    : `${length}${recording.recovered ? 'recovered after the page closed' : 'not sent yet'}`;
  return (
    <AttentionRow title={`${day} recording`} meta={meta}>
      <Button variant="primary" className="rounded-full" busy={uploading} disabled={upload !== null && !uploading} onClick={() => onTranscribe(recording)}>Transcribe</Button>
      <Menu
        label={`Options for the ${day} recording`}
        trigger={<MoreHorizontal className="h-5 w-5" />}
        items={[
          { label: 'Play or review', icon: <Play />, onSelect: () => navigate(APP_ROUTES.add) },
          { label: 'Download', icon: <Download />, onSelect: () => downloadBlob(recording.blob, recordingFileName(recording.mimeType, recording.createdAt)) },
          { kind: 'separator' },
          { label: 'Delete', icon: <Trash2 />, tone: 'danger', onSelect: () => onDelete(recording) },
        ]}
      />
    </AttentionRow>
  );
}

function AttentionRow({ title, meta, children }: { title: React.ReactNode; meta: string; children: React.ReactNode }) {
  return (
    <li className="flex items-center gap-2.5 rounded-lg bg-warning-surface py-2 pl-3 pr-2">
      <AlertCircle className="h-5 w-5 shrink-0 text-warning" aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <p className="truncate text-callout font-semibold">{title}</p>
        <p className="truncate text-meta text-text-secondary">{meta}</p>
      </div>
      <div className="flex shrink-0 items-center gap-0.5">{children}</div>
    </li>
  );
}
