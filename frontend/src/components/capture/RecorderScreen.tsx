import { useEffect, useRef } from 'react';
import { Pause, Play, Square } from 'lucide-react';
import { formatClock } from '../../lib/format';
import type { RecorderState } from '../../hooks/useRecorder';

const BARS = 32;

/**
 * The recording in progress: the whole window turns to the sunrise gradient,
 * with the state, a large clock, live levels from the microphone, and two round
 * controls at the thumb. Text on the gradient is always full white.
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
  const frame = 'fixed inset-0 z-40 flex flex-col items-center overflow-y-auto bg-hero px-6 text-center text-on-hero';

  if (state === 'requesting') {
    return (
      <section aria-label="Waiting for the microphone" className={`${frame} justify-center`} role="status">
        <p className="font-display text-[1.75rem] font-extrabold leading-tight">Allow the microphone</p>
        <p className="mt-2 max-w-xs text-callout">Your browser is asking whether Media Tools may use the microphone. Recording starts as soon as you allow it.</p>
        <button type="button" onClick={onCancelRequest} className="pressable mt-6 inline-flex min-h-11 items-center rounded-full bg-on-hero px-6 text-callout font-semibold text-hero-glyph">Cancel</button>
      </section>
    );
  }

  const paused = state === 'paused';
  const stopping = state === 'stopping';
  const started = new Date(startedAt);
  const label = new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(started);

  return (
    <section aria-label="Recording" className={`${frame} pb-[max(1.5rem,env(safe-area-inset-bottom))] pt-[max(2rem,env(safe-area-inset-top))]`}>
      <p className="mt-2 flex items-center gap-2 text-body font-semibold" role="status" aria-live="polite">
        <span className={`h-3 w-3 rounded-full bg-on-hero ${paused || stopping ? '' : 'recording-dot'}`} aria-hidden="true" />
        {stopping ? 'Saving' : paused ? 'Paused' : 'Recording'}
      </p>
      <p className="mt-8 font-display text-[4.75rem] font-extrabold leading-none tracking-[-0.015em] tabular" aria-label={`Elapsed ${formatClock(elapsed)}`}>
        {formatClock(elapsed, true)}
      </p>
      <p className="mt-7 font-display text-xl font-bold">New recording</p>
      <p className="mt-1 text-callout">{label}</p>
      <LevelMeter active={state === 'recording'} readLevels={readLevels} />

      <div className="mt-auto flex items-center gap-10 pt-8">
        <div className="flex flex-col items-center gap-2">
          <button
            type="button"
            onClick={paused ? onResume : onPause}
            disabled={stopping}
            aria-label={paused ? 'Resume recording' : 'Pause recording'}
            className="pressable flex h-[76px] w-[76px] items-center justify-center rounded-full bg-[rgb(255_255_255/0.2)] disabled:opacity-50"
          >
            {paused ? <Play className="ml-1 h-7 w-7 fill-current" aria-hidden="true" /> : <Pause className="h-7 w-7 fill-current" aria-hidden="true" />}
          </button>
          <span className="text-meta font-semibold">{paused ? 'Resume' : 'Pause'}</span>
        </div>
        <div className="flex flex-col items-center gap-2">
          <button
            type="button"
            onClick={onStop}
            disabled={stopping}
            aria-label="Stop and save"
            className="pressable flex h-[92px] w-[92px] items-center justify-center rounded-full bg-on-hero text-hero-glyph disabled:opacity-60"
          >
            <Square className="h-8 w-8 fill-current" aria-hidden="true" />
          </button>
          <span className="text-meta font-semibold">Stop</span>
        </div>
      </div>
      <p className="mt-5 max-w-xs text-meta">Keep this screen open while recording. Every second is saved on this device as you go.</p>
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
        if (bar) bar.style.transform = `scaleY(${(0.06 + shown[index] * 0.94).toFixed(3)})`;
      }
      frame = window.requestAnimationFrame(draw);
    };
    frame = window.requestAnimationFrame(draw);
    return () => window.cancelAnimationFrame(frame);
  }, [active, readLevels]);

  return (
    <div className="mt-8 flex h-24 items-center gap-[4px]" aria-hidden="true">
      {Array.from({ length: BARS }, (_, index) => (
        <span key={index} ref={(node) => { barsRef.current[index] = node; }} className="h-24 w-[3px] origin-center rounded-full bg-on-hero" style={{ transform: 'scaleY(0.06)' }} />
      ))}
    </div>
  );
}
