import { useEffect, useMemo, useRef, useState, type MutableRefObject, type PointerEvent as ReactPointerEvent } from 'react';
import { Pause, Play } from 'lucide-react';
import { formatClock } from '../../lib/format';
import { normalizeWaveform } from '../../lib/waveform';
import { Waveform } from '../ui/Waveform';

export type PlayerHandle = { seek: (seconds: number, play?: boolean) => void };

const SPEEDS = [1, 1.25, 1.5, 2, 0.75];
const BAR_SPACING_PX = 5;
const TOUCH_SLOP_PX = 6;

/**
 * The waveform player: tap or drag the waveform to seek, or use the arrow keys
 * on its slider. A recording with no waveform yet gets a plain scrubber instead.
 * The element keeps its position when the page refreshes the item in the
 * background, because the source only changes when the item does.
 */
export function AudioPlayer({ src, fallbackDuration, waveform, handleRef, onExpired, onTime }: {
  src: string;
  fallbackDuration?: number;
  waveform?: number[];
  handleRef: MutableRefObject<PlayerHandle | null>;
  /** The signed URL expired; the parent fetches a new one. */
  onExpired: () => void;
  onTime?: (seconds: number, playing: boolean) => void;
}) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const resumeAtRef = useRef<number | null>(null);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const dragRef = useRef<{ startX: number; touch: boolean; moved: boolean } | null>(null);
  const [playing, setPlaying] = useState(false);
  const [time, setTime] = useState(0);
  const [duration, setDuration] = useState(fallbackDuration || 0);
  const [speed, setSpeed] = useState(1);
  const [failed, setFailed] = useState(false);
  const [width, setWidth] = useState(0);
  const peaks = useMemo(() => normalizeWaveform(waveform), [waveform]);

  useEffect(() => {
    handleRef.current = {
      seek: (seconds, play = true) => {
        const audio = audioRef.current;
        if (!audio) return;
        audio.currentTime = Math.max(0, seconds);
        setTime(audio.currentTime);
        if (play) void audio.play().catch(() => undefined);
      },
    };
    return () => { handleRef.current = null; };
  }, [handleRef]);

  // A new signed URL for the same recording: carry on from the same moment.
  useEffect(() => {
    const audio = audioRef.current;
    if (!audio || resumeAtRef.current === null) return;
    const at = resumeAtRef.current;
    resumeAtRef.current = null;
    const restore = () => { audio.currentTime = at; };
    audio.addEventListener('loadedmetadata', restore, { once: true });
    return () => audio.removeEventListener('loadedmetadata', restore);
  }, [src]);

  // As many bars as fit, so a phone and a wide window both read cleanly.
  useEffect(() => {
    const surface = surfaceRef.current;
    if (!surface || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    observer.observe(surface);
    return () => observer.disconnect();
  }, [peaks]);

  const toggle = () => {
    const audio = audioRef.current;
    if (!audio) return;
    if (audio.paused) void audio.play().catch(() => setFailed(true));
    else audio.pause();
  };

  const cycleSpeed = () => {
    const next = SPEEDS[(SPEEDS.indexOf(speed) + 1) % SPEEDS.length];
    setSpeed(next);
    if (audioRef.current) audioRef.current.playbackRate = next;
  };

  const total = duration || fallbackDuration || 0;
  const position = Math.min(time, total || 1);

  const seekTo = (seconds: number) => {
    const audio = audioRef.current;
    if (!audio) return;
    audio.currentTime = seconds;
    setTime(audio.currentTime);
    onTime?.(audio.currentTime, !audio.paused);
  };

  const seekToPointer = (clientX: number) => {
    const rect = surfaceRef.current?.getBoundingClientRect();
    if (!rect || rect.width === 0 || !total) return;
    seekTo(Math.min(1, Math.max(0, (clientX - rect.left) / rect.width)) * total);
  };

  // A mouse seeks on press. A finger might be scrolling the page, so it seeks on
  // a tap or once it moves sideways; a vertical scroll cancels the pointer.
  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    const touch = event.pointerType !== 'mouse';
    dragRef.current = { startX: event.clientX, touch, moved: false };
    event.currentTarget.setPointerCapture(event.pointerId);
    if (!touch) seekToPointer(event.clientX);
  };
  const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag) return;
    if (drag.touch && !drag.moved && Math.abs(event.clientX - drag.startX) < TOUCH_SLOP_PX) return;
    drag.moved = true;
    seekToPointer(event.clientX);
  };
  const onPointerUp = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    dragRef.current = null;
    if (drag?.touch && !drag.moved) seekToPointer(event.clientX);
  };

  const slider = (className: string) => (
    <input
      type="range"
      min={0}
      max={total || 1}
      step={peaks ? 5 : 0.1}
      value={position}
      onChange={(event) => seekTo(Number(event.target.value))}
      aria-label="Position"
      aria-valuetext={`${formatClock(time)} of ${formatClock(total)}`}
      className={className}
      style={{ ['--progress' as string]: `${total ? (position / total) * 100 : 0}%` }}
    />
  );

  return (
    <div className="mt-3 rounded-lg bg-surface p-3.5">
      <audio
        ref={audioRef}
        src={src}
        preload="metadata"
        onPlay={(event) => { setPlaying(true); onTime?.(event.currentTarget.currentTime, true); }}
        onPause={(event) => { setPlaying(false); onTime?.(event.currentTarget.currentTime, false); }}
        onEnded={() => setPlaying(false)}
        onTimeUpdate={(event) => { setTime(event.currentTarget.currentTime); onTime?.(event.currentTarget.currentTime, !event.currentTarget.paused); }}
        onLoadedMetadata={(event) => { if (Number.isFinite(event.currentTarget.duration)) setDuration(event.currentTarget.duration); event.currentTarget.playbackRate = speed; setFailed(false); }}
        onError={() => {
          // Most often an expired link. Ask for a fresh one once.
          if (!failed) {
            resumeAtRef.current = audioRef.current?.currentTime ?? 0;
            setFailed(true);
            onExpired();
          }
        }}
      />
      {peaks ? (
        <div
          ref={surfaceRef}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onPointerCancel={() => { dragRef.current = null; }}
          className="relative h-[4.25rem] cursor-pointer touch-pan-y select-none rounded-sm has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-4 has-[:focus-visible]:outline-accent-text"
        >
          <Waveform peaks={peaks} bars={Math.max(16, Math.floor((width || 320) / BAR_SPACING_PX))} progress={total ? position / total : 0} className="h-full w-full" />
          {slider('sr-only')}
        </div>
      ) : slider('scrubber h-11 w-full')}
      <div className="mt-2 grid grid-cols-[1fr_auto_1fr] items-center">
        <span className="font-mono text-meta">{formatClock(time)}</span>
        <button type="button" onClick={toggle} aria-label={playing ? 'Pause' : 'Play recording'} className="pressable flex h-12 w-12 items-center justify-center rounded-full bg-accent-fill text-on-accent">
          {playing ? <Pause className="h-5 w-5 fill-current" /> : <Play className="ml-0.5 h-5 w-5 fill-current" />}
        </button>
        <span className="flex items-center justify-end gap-1">
          <button type="button" onClick={cycleSpeed} aria-label={`Playback speed ${speed}×`} className="pressable inline-flex h-11 min-w-11 items-center justify-center rounded-full px-1 font-mono text-meta font-semibold text-accent-text hover:bg-fill">{speed}×</button>
          <span className="font-mono text-meta text-text-secondary">{formatClock(total)}</span>
        </span>
      </div>
    </div>
  );
}
