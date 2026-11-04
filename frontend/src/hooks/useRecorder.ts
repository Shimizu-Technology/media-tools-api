import { useCallback, useEffect, useRef, useState } from 'react';
import { appendRecordingChunk, saveRecordingDraft, type PendingRecording } from '../lib/recordingStore';
import { createWakeLockKeeper, type WakeLockProvider } from '../lib/wakeLock';

export type RecorderState = 'idle' | 'requesting' | 'recording' | 'paused' | 'stopping';

export type RecorderResult = { recording: PendingRecording; warning: string; savedOnDevice: boolean };

const TIMESLICE_MS = 1000;

function pickMimeType(): string {
  if (typeof MediaRecorder === 'undefined') return '';
  for (const candidate of ['audio/mp4;codecs=mp4a.40.2', 'audio/mp4', 'audio/webm;codecs=opus', 'audio/webm']) {
    if (MediaRecorder.isTypeSupported(candidate)) return candidate;
  }
  return '';
}

async function measureDuration(blob: Blob): Promise<number | null> {
  if (typeof Audio === 'undefined') return null;
  return await new Promise((resolve) => {
    const audio = new Audio();
    const url = URL.createObjectURL(blob);
    const finish = (value: number | null) => { URL.revokeObjectURL(url); resolve(value); };
    const timer = window.setTimeout(() => finish(null), 4000);
    audio.preload = 'metadata';
    audio.onloadedmetadata = () => { window.clearTimeout(timer); finish(Number.isFinite(audio.duration) && audio.duration > 0 ? audio.duration : null); };
    audio.onerror = () => { window.clearTimeout(timer); finish(null); };
    audio.src = url;
  });
}

export function recorderSupported(): boolean {
  return typeof window !== 'undefined' && typeof MediaRecorder !== 'undefined' && Boolean(navigator.mediaDevices?.getUserMedia);
}

/**
 * Microphone recording that cannot quietly lose audio.
 *
 * - Every second of audio is written to this device as it is recorded.
 * - The screen is kept awake while recording, where the browser allows it.
 * - If the microphone goes away (unplugged, taken by a call), recording stops
 *   and what was captured is kept.
 * - Unmounting (leaving the page) stops the microphone and saves the draft.
 */
export function useRecorder() {
  const [state, setState] = useState<RecorderState>('idle');
  const [elapsed, setElapsed] = useState(0);
  const [error, setError] = useState('');
  const [startedAt, setStartedAt] = useState(() => Date.now());
  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const sessionRef = useRef<{ id: string; startedAt: number; seq: number; mimeType: string } | null>(null);
  const accumulatedRef = useRef(0);
  const segmentStartRef = useRef<number | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const stopWaitersRef = useRef<Array<(result: RecorderResult | null) => void>>([]);
  const deviceSaveFailedRef = useRef(false);
  const mountedRef = useRef(true);
  const requestCancelledRef = useRef(false);

  const elapsedSeconds = useCallback(() => {
    const running = segmentStartRef.current === null ? 0 : performance.now() - segmentStartRef.current;
    return (accumulatedRef.current + running) / 1000;
  }, []);

  // The browser drops the lock whenever the tab is hidden; the keeper notices
  // and asks again on return. It only holds one while a microphone stream is live.
  const wakeLockRef = useRef<ReturnType<typeof createWakeLockKeeper> | null>(null);
  const wakeLock = useCallback(() => {
    wakeLockRef.current ??= createWakeLockKeeper({
      provider: () => (navigator as Navigator & { wakeLock?: WakeLockProvider }).wakeLock,
      wanted: () => document.visibilityState === 'visible' && streamRef.current !== null,
    });
    return wakeLockRef.current;
  }, []);

  const releaseResources = useCallback(() => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    wakeLock().release();
    analyserRef.current = null;
    void audioContextRef.current?.close().catch(() => undefined);
    audioContextRef.current = null;
  }, [wakeLock]);

  // Clock: redraw a few times a second while recording.
  useEffect(() => {
    if (state !== 'recording') return;
    const timer = window.setInterval(() => setElapsed(elapsedSeconds()), 250);
    return () => window.clearInterval(timer);
  }, [elapsedSeconds, state]);

  // The wake lock drops when the tab is hidden; take it back on return.
  useEffect(() => {
    if (state !== 'recording' && state !== 'paused') return;
    const onVisible = () => { if (document.visibilityState === 'visible') void wakeLock().acquire(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [state, wakeLock]);

  const finish = useCallback(async (): Promise<RecorderResult | null> => {
    const session = sessionRef.current;
    sessionRef.current = null;
    releaseResources();
    if (!session) return null;
    const shownSeconds = elapsedSeconds();
    segmentStartRef.current = null;
    const blob = new Blob(chunksRef.current, { type: session.mimeType });
    chunksRef.current = [];
    if (blob.size === 0) return null;
    const measured = await measureDuration(blob);
    let warning = '';
    if (shownSeconds >= 120 && blob.size < 1024 * 1024) warning = 'This recording looks shorter than the time shown. The browser may have stopped capturing while the screen was off.';
    else if (measured !== null && shownSeconds >= 120 && measured < 10) warning = 'This recording appears cut short on this device. Keep the screen on while recording.';
    const recording: PendingRecording = {
      id: session.id,
      blob,
      mimeType: session.mimeType,
      durationSeconds: Math.max(1, Math.round(measured ?? shownSeconds)),
      createdAt: session.startedAt,
    };
    let savedOnDevice = true;
    try {
      await saveRecordingDraft(recording);
    } catch {
      savedOnDevice = false;
    }
    return { recording, warning, savedOnDevice: savedOnDevice && !deviceSaveFailedRef.current };
  }, [elapsedSeconds, releaseResources]);

  const settleStop = useCallback((result: RecorderResult | null) => {
    const waiters = stopWaitersRef.current;
    stopWaitersRef.current = [];
    waiters.forEach((resolve) => resolve(result));
  }, []);

  const stop = useCallback((): Promise<RecorderResult | null> => {
    const recorder = recorderRef.current;
    if (!recorder || recorder.state === 'inactive') return Promise.resolve(null);
    setState('stopping');
    if (segmentStartRef.current !== null) {
      accumulatedRef.current += performance.now() - segmentStartRef.current;
      segmentStartRef.current = null;
    }
    return new Promise((resolve) => {
      stopWaitersRef.current.push(resolve);
      try { recorder.stop(); } catch { void finish().then(settleStop); }
    });
  }, [finish, settleStop]);

  const start = useCallback(async () => {
    if (state !== 'idle') return;
    setError('');
    if (!recorderSupported()) {
      setError('This browser cannot record audio. Upload a recording instead.');
      return;
    }
    setState('requesting');
    requestCancelledRef.current = false;
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    } catch (caught) {
      if (requestCancelledRef.current) return;
      setState('idle');
      const name = caught instanceof DOMException ? caught.name : '';
      setError(name === 'NotAllowedError' || name === 'SecurityError'
        ? 'Microphone access is off for this site. Allow it in the browser’s site settings, then try again.'
        : name === 'NotFoundError' ? 'No microphone was found.' : 'The microphone could not start. Try again.');
      return;
    }
    // The page was left, or the person gave up, while the permission prompt was open.
    if (!mountedRef.current || requestCancelledRef.current) {
      stream.getTracks().forEach((track) => track.stop());
      return;
    }
    const mimeType = pickMimeType();
    let recorder: MediaRecorder;
    try {
      recorder = mimeType ? new MediaRecorder(stream, { mimeType }) : new MediaRecorder(stream);
    } catch {
      stream.getTracks().forEach((track) => track.stop());
      setState('idle');
      setError('This browser cannot record audio. Upload a recording instead.');
      return;
    }
    const session = { id: globalThis.crypto?.randomUUID?.() ?? `rec-${Date.now()}`, startedAt: Date.now(), seq: 0, mimeType: recorder.mimeType || mimeType || 'audio/webm' };
    sessionRef.current = session;
    setStartedAt(session.startedAt);
    streamRef.current = stream;
    recorderRef.current = recorder;
    chunksRef.current = [];
    accumulatedRef.current = 0;
    deviceSaveFailedRef.current = false;

    recorder.ondataavailable = (event) => {
      if (event.data.size === 0) return;
      chunksRef.current.push(event.data);
      const active = sessionRef.current;
      if (!active) return;
      const seq = active.seq++;
      appendRecordingChunk({ sessionId: active.id, seq, blob: event.data, mimeType: active.mimeType, startedAt: active.startedAt, at: Date.now() })
        .catch(() => { deviceSaveFailedRef.current = true; });
    };
    recorder.onstop = () => { void finish().then((result) => { setState('idle'); settleStop(result); }); };
    recorder.onerror = () => {
      setError('Recording stopped because of a browser error. What was captured is saved.');
      void stop();
    };
    stream.getAudioTracks().forEach((track) => {
      track.onended = () => {
        if (recorderRef.current?.state !== 'inactive') {
          setError('The microphone stopped. What was recorded is saved.');
          void stop();
        }
      };
    });

    // A level meter, so it is obvious the microphone hears something.
    try {
      const AudioContextClass = window.AudioContext ?? (window as Window & { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (AudioContextClass) {
        const context = new AudioContextClass();
        const analyser = context.createAnalyser();
        analyser.fftSize = 512;
        context.createMediaStreamSource(stream).connect(analyser);
        audioContextRef.current = context;
        analyserRef.current = analyser;
      }
    } catch { /* The meter is optional. */ }

    recorder.start(TIMESLICE_MS);
    segmentStartRef.current = performance.now();
    setElapsed(0);
    setState('recording');
    void wakeLock().acquire();
  }, [finish, settleStop, state, stop, wakeLock]);

  /** Give up waiting for the permission prompt. */
  const cancelRequest = useCallback(() => {
    requestCancelledRef.current = true;
    setState('idle');
  }, []);

  const pause = useCallback(() => {
    const recorder = recorderRef.current;
    if (!recorder || recorder.state !== 'recording') return;
    // Flush the current second first, so it is on disk while paused.
    recorder.requestData();
    recorder.pause();
    if (segmentStartRef.current !== null) {
      accumulatedRef.current += performance.now() - segmentStartRef.current;
      segmentStartRef.current = null;
    }
    setElapsed(elapsedSeconds());
    setState('paused');
  }, [elapsedSeconds]);

  const resume = useCallback(() => {
    const recorder = recorderRef.current;
    if (!recorder || recorder.state !== 'paused') return;
    recorder.resume();
    segmentStartRef.current = performance.now();
    setState('recording');
  }, []);

  // Leaving the page stops the microphone; the draft is saved by onstop.
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      const recorder = recorderRef.current;
      if (recorder && recorder.state !== 'inactive') {
        try { recorder.stop(); } catch { /* Already stopped. */ }
      } else {
        releaseResources();
      }
    };
  }, [releaseResources]);

  /** Fills `levels` (0..1) from the microphone; false when no meter is available. */
  const readLevels = useCallback((levels: Float32Array): boolean => {
    const analyser = analyserRef.current;
    if (!analyser) return false;
    const data = new Uint8Array(analyser.fftSize);
    analyser.getByteTimeDomainData(data);
    const step = Math.floor(data.length / levels.length);
    for (let index = 0; index < levels.length; index += 1) {
      let peak = 0;
      for (let offset = 0; offset < step; offset += 1) peak = Math.max(peak, Math.abs(data[index * step + offset] - 128));
      levels[index] = Math.min(1, peak / 64);
    }
    return true;
  }, []);

  return { state, elapsed, startedAt, error, setError, start, stop, pause, resume, cancelRequest, readLevels, active: state === 'recording' || state === 'paused' || state === 'stopping' || state === 'requesting' };
}
