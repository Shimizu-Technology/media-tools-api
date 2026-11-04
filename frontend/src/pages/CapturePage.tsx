import { useCallback, useEffect, useRef, useState, type DragEvent, type FormEvent } from 'react';
import { Link, useBlocker, useNavigate, useSearchParams } from 'react-router-dom';
import { Download, FileUp, Link2, Mic, Play, Trash2, Upload } from 'lucide-react';
import { getErrorMessage } from '../lib/api';
import { downloadBlob } from '../lib/download';
import { hasUnsavedRecording, holdRecording, releaseRecording, type HeldRecording } from '../lib/heldRecordings';
import { itemDetailPath } from '../lib/library';
import { formatClock, formatItemDate } from '../lib/format';
import { addPDF, addVideoLink, classifyFile, isAbortError, looksLikeURL, recordingFileName, uploadAudio } from '../lib/mediaUpload';
import { createOperationSlot } from '../lib/operation';
import { deleteRecordingDraft, listRecordingDrafts, recoverInterruptedRecordings, type PendingRecording } from '../lib/recordingStore';
import { recorderSupported, useRecorder } from '../hooks/useRecorder';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { RecorderScreen } from '../components/capture/RecorderScreen';
import { Button } from '../components/ui/Button';
import { Dialog } from '../components/ui/Dialog';
import { Input, Notice } from '../components/ui/Field';

// Written by the previous recording page while a job ran; read once so that job is not lost track of.
const LEGACY_ACTIVE_AUDIO_KEY = 'mta_active_audio_transcription_id';

type Upload = { label: string; progress: number | null };

/**
 * One place to add anything: record, paste a link, or choose a file. Every
 * path ends on the new item, where the transcript and summary arrive.
 */
export function CapturePage() {
  const [params, setParams] = useSearchParams();
  const navigate = useNavigate();
  const recorder = useRecorder();
  const { requestConsent } = useAIProcessingConsent();
  const [drafts, setDrafts] = useState<PendingRecording[]>([]);
  const [upload, setUpload] = useState<Upload | null>(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [held, setHeld] = useState<HeldRecording[]>([]);
  const [link, setLink] = useState('');
  const [dragging, setDragging] = useState(false);
  const [legacyJob, setLegacyJob] = useState<string | null>(() => {
    try { return localStorage.getItem(LEGACY_ACTIVE_AUDIO_KEY); } catch { return null; }
  });
  const fileRef = useRef<HTMLInputElement>(null);
  const linkRef = useRef<HTMLInputElement>(null);
  const busyRef = useRef(false);
  const autoStartRef = useRef(false);
  const [operations] = useState(createOperationSlot);
  const busy = recorder.active || upload !== null;
  useEffect(() => { busyRef.current = busy; }, [busy]);
  // A recording the browser could not store exists only on this page.
  const unsaved = hasUnsavedRecording(held);
  const unsavedRef = useRef(false);
  useEffect(() => { unsavedRef.current = unsaved; }, [unsaved]);

  // One upload at a time. Leaving the page aborts the request and makes every
  // callback it queued a no-op, so a finished upload cannot steer navigation
  // the person has already chosen.
  const beginOperation = operations.begin;
  const cancelOperation = operations.cancel;
  useEffect(() => cancelOperation, [cancelOperation]);

  const hold = (entry: HeldRecording) => setHeld((list) => holdRecording(list, entry));
  const release = (id: string) => setHeld((list) => releaseRecording(list, id));

  const refreshDrafts = useCallback(async () => {
    try { setDrafts(await listRecordingDrafts()); } catch { /* Storage blocked: nothing to show. */ }
  }, []);

  useEffect(() => {
    void recoverInterruptedRecordings().catch(() => 0).then(() => refreshDrafts());
  }, [refreshDrafts]);

  // ?record=1 (the Library's Record button) starts at once: one tap to record.
  useEffect(() => {
    if (params.get('record') !== '1' || autoStartRef.current) return;
    autoStartRef.current = true;
    const next = new URLSearchParams(params);
    next.delete('record');
    setParams(next, { replace: true });
    void recorder.start();
  }, [params, recorder, setParams]);

  useEffect(() => {
    const source = params.get('source');
    if (source === 'link') linkRef.current?.focus();
  }, [params]);

  // Hold navigation while recording, uploading, or keeping a recording that
  // exists only on this page. Leaving after confirming stops the microphone and
  // cancels the upload; a recording stored on this device stays there as a draft.
  const blocker = useBlocker(({ currentLocation, nextLocation }) => (busyRef.current || unsavedRef.current) && currentLocation.pathname !== nextLocation.pathname);
  const guarded = busy || unsaved;
  useEffect(() => {
    if (!guarded) return;
    const onBeforeUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ''; };
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [guarded]);

  const finishedOn = (path: string) => {
    busyRef.current = false;
    setUpload(null);
    navigate(path, { replace: true });
  };

  const uploadDraft = async (draft: PendingRecording, context: { savedOnDevice: boolean; warning?: string } = { savedOnDevice: true }) => {
    setError('');
    setNotice('');
    // In memory first: nothing below may be the only place the audio lives.
    hold({ recording: draft, warning: context.warning ?? '', savedOnDevice: context.savedOnDevice });
    const operation = beginOperation();
    if (!(await requestConsent())) {
      if (!operation.live()) return;
      setNotice(context.savedOnDevice
        ? 'Saved on this device. Upload it when you are ready to transcribe it.'
        : 'Not uploaded yet. Download a copy or upload it when you are ready; it is only on this page.');
      return;
    }
    if (!operation.live()) return;
    busyRef.current = true;
    setUpload({ label: 'Uploading your recording', progress: 0 });
    try {
      const file = new File([draft.blob], recordingFileName(draft.mimeType, draft.createdAt), { type: draft.blob.type || draft.mimeType });
      const transcription = await uploadAudio(file, (percent) => { if (operation.live()) setUpload((current) => current && { ...current, progress: percent < 0 ? null : percent }); }, operation.signal);
      // The server has it: the copy on this device is no longer needed, even if the person already left.
      await deleteRecordingDraft(draft.id).catch(() => undefined);
      if (!operation.live()) return;
      release(draft.id);
      finishedOn(itemDetailPath('audio', transcription.id));
    } catch (err) {
      // Left on purpose: keep the draft exactly as it was and say nothing.
      if (!operation.live() || isAbortError(err)) return;
      busyRef.current = false;
      setUpload(null);
      setError(`The upload did not finish: ${getErrorMessage(err)} ${context.savedOnDevice
        ? 'The recording is still saved on this device.'
        : 'The recording is kept on this page. Play it, download a copy, or try again.'}`);
      await refreshDrafts();
    }
  };

  const uploadHeld = (entry: HeldRecording) => void uploadDraft(entry.recording, { savedOnDevice: entry.savedOnDevice, warning: entry.warning });

  const stopRecording = async () => {
    const result = await recorder.stop();
    if (!result) {
      setError((current) => current || 'Nothing was recorded. Check the microphone and try again.');
      return;
    }
    const entry = { recording: result.recording, warning: result.warning, savedOnDevice: result.savedOnDevice };
    hold(entry);
    if (result.warning) {
      // Let the person hear it before it is uploaded.
      await refreshDrafts();
      return;
    }
    await uploadDraft(entry.recording, entry);
  };

  const discardDraft = async (draft: PendingRecording, savedOnDevice = true) => {
    if (!window.confirm(savedOnDevice
      ? 'Delete this recording from this device? It has not been uploaded.'
      : 'Delete this recording? It has not been uploaded and is not saved anywhere else.')) return;
    await deleteRecordingDraft(draft.id).catch(() => undefined);
    release(draft.id);
    await refreshDrafts();
  };

  const addFile = async (file: File) => {
    setError('');
    setNotice('');
    const kind = classifyFile(file);
    if ('error' in kind) return setError(kind.error);
    const operation = beginOperation();
    if (kind.kind === 'audio' && !(await requestConsent())) {
      if (!operation.live()) return;
      setNotice('Nothing was uploaded. Transcription needs permission to use AI processing.');
      return;
    }
    if (!operation.live()) return;
    busyRef.current = true;
    setUpload({ label: kind.kind === 'pdf' ? `Reading ${file.name}` : `Uploading ${file.name}`, progress: kind.kind === 'pdf' ? null : 0 });
    try {
      if (kind.kind === 'pdf') {
        const extraction = await addPDF(file, operation.signal);
        if (operation.live()) finishedOn(itemDetailPath('pdf', extraction.id));
      } else {
        const transcription = await uploadAudio(file, (percent) => { if (operation.live()) setUpload((current) => current && { ...current, progress: percent < 0 ? null : percent }); }, operation.signal);
        if (operation.live()) finishedOn(itemDetailPath('audio', transcription.id));
      }
    } catch (err) {
      if (!operation.live() || isAbortError(err)) return;
      busyRef.current = false;
      setUpload(null);
      setError(getErrorMessage(err));
    }
  };

  const submitLink = async (event: FormEvent) => {
    event.preventDefault();
    setError('');
    if (!looksLikeURL(link)) return setError('Paste the full link, starting with https://');
    const operation = beginOperation();
    busyRef.current = true;
    setUpload({ label: 'Adding the video', progress: null });
    try {
      const transcript = await addVideoLink(link, operation.signal);
      if (operation.live()) finishedOn(itemDetailPath('transcript', transcript.id));
    } catch (err) {
      if (!operation.live() || isAbortError(err)) return;
      busyRef.current = false;
      setUpload(null);
      setError(getErrorMessage(err));
    }
  };

  const onDrop = (event: DragEvent) => {
    event.preventDefault();
    setDragging(false);
    const file = event.dataTransfer.files[0];
    if (file) void addFile(file);
  };

  const leaving = recorder.active ? 'recording' : upload ? 'upload' : 'unsaved';
  const leaveDialog = (
    <Dialog
      open={blocker.state === 'blocked'}
      onClose={() => blocker.reset?.()}
      title={leaving === 'recording' ? 'Still recording' : leaving === 'upload' ? 'Upload in progress' : 'Recording not saved'}
      footer={(
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button onClick={() => blocker.reset?.()}>{leaving === 'recording' ? 'Keep recording' : 'Stay'}</Button>
          <Button variant="danger" onClick={() => void (async () => {
            if (recorder.active) await recorder.stop();
            // Stop the request and ignore whatever it reports, so it cannot redirect away from where the person chose to go.
            cancelOperation();
            busyRef.current = false;
            unsavedRef.current = false;
            blocker.proceed?.();
          })()}>
            {leaving === 'recording' ? 'Stop and leave' : leaving === 'upload' ? 'Leave' : 'Leave and lose it'}
          </Button>
        </div>
      )}
    >
      <p className="text-callout text-text-secondary">
        {leaving === 'recording'
          ? 'Leaving stops the recording. What you have recorded is saved on this device, and you can upload it from Add.'
          : leaving === 'upload'
            ? 'Leaving stops the upload. A recording stays saved on this device; a chosen file needs to be added again.'
            : 'This browser could not save your recording on this device, so it exists only on this page. Stay and download it first, or leaving will lose it.'}
      </p>
    </Dialog>
  );

  if (recorder.active) {
    return (
      <>
        <RecorderScreen state={recorder.state} elapsed={recorder.elapsed} startedAt={recorder.startedAt} readLevels={recorder.readLevels} onPause={recorder.pause} onResume={recorder.resume} onStop={() => void stopRecording()} onCancelRequest={recorder.cancelRequest} />
        {leaveDialog}
      </>
    );
  }

  if (upload) {
    return (
      <section className="mx-auto flex min-h-[60dvh] max-w-md flex-col justify-center" aria-live="polite">
        <p className="text-title">{upload.label}</p>
        <div className="mt-5 h-1 overflow-hidden rounded-full bg-separator" role="progressbar" aria-label={upload.label} aria-valuemin={0} aria-valuemax={100} aria-valuenow={upload.progress ?? undefined}>
          {upload.progress === null
            ? <div className="h-full w-1/3 animate-pulse rounded-full bg-accent-fill" />
            : <div className="h-full rounded-full bg-accent-fill transition-[width] duration-300" style={{ width: `${Math.max(3, upload.progress)}%` }} />}
        </div>
        <p className="mt-3 text-callout text-text-secondary">{upload.progress !== null ? `${upload.progress}% · ` : ''}Keep this page open until it finishes. Then the item opens and the transcript fills in by itself.</p>
        {leaveDialog}
      </section>
    );
  }

  return (
    <div className="mx-auto max-w-xl pb-10">
      <h1 className="pt-2 text-large-title">Add</h1>

      {legacyJob && (
        <div className="mt-4">
          <Notice action={<Link to={itemDetailPath('audio', legacyJob)} onClick={() => { try { localStorage.removeItem(LEGACY_ACTIVE_AUDIO_KEY); } catch { /* ignore */ } }} className="inline-flex min-h-11 items-center px-2 font-semibold text-accent">Open</Link>}>
            Your last upload from this browser is in the library.
            <button type="button" className="ml-1 inline-flex min-h-11 items-center text-text-secondary underline" onClick={() => { try { localStorage.removeItem(LEGACY_ACTIVE_AUDIO_KEY); } catch { /* ignore */ } setLegacyJob(null); }}>Dismiss</button>
          </Notice>
        </div>
      )}

      {error && <div className="mt-4"><Notice tone="error">{error}</Notice></div>}
      {(notice || recorder.error) && <div className="mt-4"><Notice>{recorder.error || notice}</Notice></div>}

      {held.length > 0 && (
        <ul className="mt-4 space-y-3" aria-label="Recordings not uploaded yet">
          {held.map((entry) => <HeldCard key={entry.recording.id} entry={entry} onUpload={() => uploadHeld(entry)} onDelete={() => void discardDraft(entry.recording, entry.savedOnDevice)} />)}
        </ul>
      )}

      <section className="mt-6" aria-labelledby="record-heading">
        <h2 id="record-heading" className="sr-only">Record</h2>
        {recorderSupported() ? (
          <Button variant="primary" size="lg" block onClick={() => void recorder.start()} icon={<Mic className="h-5 w-5" aria-hidden="true" />}>Record</Button>
        ) : (
          <Notice>This browser cannot record. Record with your phone’s voice memo app, then choose the file below.</Notice>
        )}
      </section>

      {drafts.filter((draft) => !held.some((entry) => entry.recording.id === draft.id)).length > 0 && (
        <section className="mt-8" aria-labelledby="drafts-heading">
          <h2 id="drafts-heading" className="text-heading">Not uploaded yet</h2>
          <p className="mt-1 text-callout text-text-secondary">Saved on this device only.</p>
          <ul className="mt-2 divide-y divide-separator">
            {drafts.filter((draft) => !held.some((entry) => entry.recording.id === draft.id)).map((draft) => <DraftRow key={draft.id} draft={draft} onUpload={() => void uploadDraft(draft)} onDelete={() => void discardDraft(draft)} />)}
          </ul>
        </section>
      )}

      <section className="mt-8" aria-labelledby="link-heading">
        <h2 id="link-heading" className="text-heading">Paste a link</h2>
        <p className="mt-1 text-callout text-text-secondary">YouTube, Vimeo, and most video sites with captions or speech.</p>
        <form onSubmit={(event) => void submitLink(event)} className="mt-3 flex gap-2">
          <div className="relative min-w-0 flex-1">
            <Link2 className="pointer-events-none absolute left-3 top-1/2 h-[18px] w-[18px] -translate-y-1/2 text-text-secondary" aria-hidden="true" />
            <Input ref={linkRef} type="url" inputMode="url" autoComplete="off" autoCapitalize="none" spellCheck={false} value={link} onChange={(event) => setLink(event.target.value)} placeholder="https://" aria-label="Video link" className="pl-10" />
          </div>
          <Button type="submit" variant="secondary" disabled={!link.trim()}>Add</Button>
        </form>
      </section>

      <section className="mt-8" aria-labelledby="file-heading">
        <h2 id="file-heading" className="text-heading">Choose a file</h2>
        <button
          type="button"
          onClick={() => fileRef.current?.click()}
          onDragOver={(event) => { event.preventDefault(); setDragging(true); }}
          onDragLeave={() => setDragging(false)}
          onDrop={onDrop}
          className={`pressable mt-3 flex min-h-28 w-full flex-col items-center justify-center gap-1 rounded-lg border border-dashed px-4 py-5 text-center hover:bg-fill ${dragging ? 'border-accent bg-accent-tint' : 'border-separator'}`}
        >
          <FileUp className="h-6 w-6 text-accent" aria-hidden="true" />
          <span className="text-body font-semibold text-accent">Choose audio, video or a PDF</span>
          <span className="text-meta text-text-secondary">Or drop it here. Up to 2 GB; PDFs up to 50 MB.</span>
        </button>
        <input ref={fileRef} type="file" hidden accept="audio/*,video/*,.m4a,.mp3,.wav,.caf,.aac,.ogg,.flac,.webm,.mp4,.mov,.qta,.pdf,application/pdf" onChange={(event) => { const file = event.target.files?.[0]; event.target.value = ''; if (file) void addFile(file); }} />
      </section>
      {leaveDialog}
    </div>
  );
}

function DraftRow({ draft, onUpload, onDelete }: { draft: PendingRecording; onUpload: () => void; onDelete: () => void }) {
  const [url, setUrl] = useState('');
  useEffect(() => () => { if (url) URL.revokeObjectURL(url); }, [url]);
  return (
    <li className="py-3">
      <div className="flex items-center gap-2">
        <div className="min-w-0 flex-1">
          <p className="text-row-title">{draft.recovered ? 'Recovered recording' : 'Recording'}</p>
          <p className="text-meta text-text-secondary tabular">{formatItemDate(new Date(draft.createdAt).toISOString())}{draft.durationSeconds ? ` · ${formatClock(draft.durationSeconds)}` : ''}</p>
        </div>
        <Button variant="plain" onClick={() => setUrl((current) => current || URL.createObjectURL(draft.blob))} aria-label="Play this recording" icon={<Play className="h-4 w-4" />}><span className="hidden sm:inline">Play</span></Button>
        <Button variant="plain" onClick={() => downloadBlob(draft.blob, recordingFileName(draft.mimeType, draft.createdAt))} aria-label="Download this recording" icon={<Download className="h-4 w-4" />} />
        <Button variant="primary" onClick={onUpload} icon={<Upload className="h-4 w-4" />}>Upload</Button>
        <Button variant="danger-plain" onClick={onDelete} aria-label="Delete this recording" icon={<Trash2 className="h-4 w-4" />} />
      </div>
      {url && <audio controls autoPlay src={url} className="mt-2 w-full" />}
    </li>
  );
}

function HeldCard({ entry, onUpload, onDelete }: { entry: HeldRecording; onUpload: () => void; onDelete: () => void }) {
  const { recording, warning, savedOnDevice } = entry;
  return (
    <li className="rounded-lg border border-separator bg-surface p-4">
      <p className="text-subheading">{warning ? 'Check this recording' : 'Not uploaded yet'}</p>
      <p className="mt-0.5 text-meta text-text-secondary tabular">{formatItemDate(new Date(recording.createdAt).toISOString())}{recording.durationSeconds ? ` · ${formatClock(recording.durationSeconds)}` : ''}</p>
      {warning && <p className="mt-1 text-callout text-text-secondary">{warning}</p>}
      <p className="mt-1 text-callout text-text-secondary">
        {savedOnDevice
          ? 'Saved on this device.'
          : 'This browser could not save it on this device, so it exists only on this page. Download a copy, and keep this page open until it is uploaded.'}
      </p>
      <BlobAudio blob={recording.blob} />
      <div className="mt-3 flex flex-wrap gap-2">
        <Button variant="primary" onClick={onUpload} icon={<Upload className="h-4 w-4" />}>{warning ? 'Upload anyway' : 'Upload'}</Button>
        <Button onClick={() => downloadBlob(recording.blob, recordingFileName(recording.mimeType, recording.createdAt))} icon={<Download className="h-4 w-4" />}>Download</Button>
        <Button variant="danger-plain" onClick={onDelete}>Delete</Button>
      </div>
    </li>
  );
}

function BlobAudio({ blob }: { blob: Blob }) {
  const [url, setUrl] = useState('');
  // Created in an effect, not state initialisation: React's development
  // double-run revokes the first URL, and the second must be a fresh one.
  useEffect(() => {
    const next = URL.createObjectURL(blob);
    queueMicrotask(() => setUrl(next));
    return () => URL.revokeObjectURL(next);
  }, [blob]);
  return url ? <audio controls src={url} aria-label="Play this recording" className="mt-3 w-full" /> : null;
}
