import { useEffect, useRef } from 'react';
import { Pause, Play, Square } from 'lucide-react';
import { formatClock } from '../../lib/format';
import type { RecorderState } from '../../hooks/useRecorder';
import { Button } from '../ui/Button';

const BARS = 28;

/**
 * The recording in progress, after the Ledger mockup: state in red, a large
 * serif clock, a live level meter, and two round controls at the thumb.
 */
export function RecorderScreen({ state, elapsed, startedAt, readLevels, onPause, onResume, onStop, onCancelRequest }: {
  state: RecorderState;
  elapsed: number;
  startedAt: number;
  readLevels: (levels: Float32Array) => boolean;
  onPause: () => void;
  onResume: () => void;
  onStop: () => void;
  onCancelRequest: () => void;
}) {
  if (state === 'requesting') {
    return (
      <section aria-label="Waiting for the microphone" className="flex min-h-[calc(100dvh-8rem)] flex-col items-center justify-center pb-16 text-center" role="status">
        <p className="text-title">Allow the microphone</p>
        <p className="mt-2 max-w-xs text-callout text-text-secondary">Your browser is asking whether Media Tools may use the microphone. Recording starts as soon as you allow it.</p>
        <Button className="mt-6" onClick={onCancelRequest}>Cancel</Button>
      </section>
    );
  }

  const paused = state === 'paused';
  const stopping = state === 'stopping';
  const started = new Date(startedAt);
  const label = new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(started);

  return (
    <section aria-label="Recording" className="flex min-h-[calc(100dvh-8rem)] flex-col items-center pb-[max(1.5rem,env(safe-area-inset-bottom))] pt-8 text-center">
      <p className="flex items-center gap-2 text-body font-semibold text-record" role="status" aria-live="polite">
        <span className={`h-3 w-3 rounded-full bg-record ${paused || stopping ? '' : 'recording-dot'}`} aria-hidden="true" />
        {stopping ? 'Saving' : paused ? 'Paused' : 'Recording'}
      </p>
      <p className="mt-10 font-serif text-[4.75rem] font-medium leading-none tracking-[-0.01em] tabular" aria-label={`Elapsed ${formatClock(elapsed)}`}>
        {formatClock(elapsed, true)}
      </p>
      <p className="mt-9 text-heading">New recording</p>
      <p className="mt-1 text-callout text-text-secondary">{label}</p>
      <LevelMeter active={state === 'recording'} readLevels={readLevels} />

      <div className="mt-auto flex items-start gap-14 pt-10">
        <div className="flex flex-col items-center gap-2.5">
          <button
            type="button"
            onClick={paused ? onResume : onPause}
            disabled={stopping}
            aria-label={paused ? 'Resume recording' : 'Pause recording'}
            className="pressable flex h-[76px] w-[76px] items-center justify-center rounded-full border border-separator bg-surface text-text disabled:opacity-50"
          >
            {paused ? <Play className="ml-1 h-7 w-7 fill-current" aria-hidden="true" /> : <Pause className="h-7 w-7 fill-current" aria-hidden="true" />}
          </button>
          <span className="text-meta font-semibold text-text-secondary">{paused ? 'Resume' : 'Pause'}</span>
        </div>
        <div className="flex flex-col items-center gap-2.5">
          <button
            type="button"
            onClick={onStop}
            disabled={stopping}
            aria-label="Stop and save"
            className="pressable flex h-[76px] w-[76px] items-center justify-center rounded-full bg-record text-on-record disabled:opacity-60"
          >
            <Square className="h-6 w-6 fill-current" aria-hidden="true" />
          </button>
          <span className="text-meta font-semibold text-text-secondary">Stop</span>
        </div>
      </div>
      <p className="mt-6 max-w-xs text-meta text-text-secondary">Keep this screen open while recording. Every second is saved on this device as you go.</p>
    </section>
  );
}

/** Bars driven straight from the analyser, without re-rendering React. */
function LevelMeter({ active, readLevels }: { active: boolean; readLevels: (levels: Float32Array) => boolean }) {
  const barsRef = useRef<Array<HTMLSpanElement | null>>([]);

  useEffect(() => {
    const levels = new Float32Array(BARS);
    const shown = new Float32Array(BARS);
    let frame = 0;
    const draw = () => {
      const live = active && readLevels(levels);
      for (let index = 0; index < BARS; index += 1) {
        const target = live ? levels[index] : 0;
        // Rise at once, fall back gently.
        shown[index] = target > shown[index] ? target : shown[index] * 0.86;
        const bar = barsRef.current[index];
        if (bar) bar.style.transform = `scaleY(${(0.12 + shown[index] * 0.88).toFixed(3)})`;
      }
      frame = window.requestAnimationFrame(draw);
    };
    frame = window.requestAnimationFrame(draw);
    return () => window.cancelAnimationFrame(frame);
  }, [active, readLevels]);

  return (
    <div className="mt-10 flex h-10 items-center gap-[3px]" aria-hidden="true">
      {Array.from({ length: BARS }, (_, index) => (
        <span key={index} ref={(node) => { barsRef.current[index] = node; }} className="h-10 w-[3px] origin-center rounded-full bg-text-secondary opacity-75" style={{ transform: 'scaleY(0.12)' }} />
      ))}
    </div>
  );
}
