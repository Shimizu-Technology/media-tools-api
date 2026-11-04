import { useEffect, useRef, useState, type MutableRefObject } from 'react';
import { Pause, Play } from 'lucide-react';
import { formatClock } from '../../lib/format';

export type PlayerHandle = { seek: (seconds: number, play?: boolean) => void };

const SPEEDS = [1, 1.25, 1.5, 2, 0.75];

/**
 * A quiet audio control: play, a thin scrubber, the time, and speed. The
 * element keeps its position when the page refreshes the item in the
 * background, because the source only changes when the item does.
 */
export function AudioPlayer({ src, fallbackDuration, handleRef, onExpired }: {
  src: string;
  fallbackDuration?: number;
  handleRef: MutableRefObject<PlayerHandle | null>;
  /** The signed URL expired; the parent fetches a new one. */
  onExpired: () => void;
}) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const resumeAtRef = useRef<number | null>(null);
  const [playing, setPlaying] = useState(false);
  const [time, setTime] = useState(0);
  const [duration, setDuration] = useState(fallbackDuration || 0);
  const [speed, setSpeed] = useState(1);
  const [failed, setFailed] = useState(false);

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

  return (
    <div className="mt-4 flex min-h-11 items-center gap-2">
      <audio
        ref={audioRef}
        src={src}
        preload="metadata"
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onTimeUpdate={(event) => setTime(event.currentTarget.currentTime)}
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
      <button type="button" onClick={toggle} aria-label={playing ? 'Pause' : 'Play recording'} className="pressable -ml-1 flex h-11 w-11 shrink-0 items-center justify-center rounded-full">
        <span className="flex h-9 w-9 items-center justify-center rounded-full bg-accent-fill text-on-accent">
          {playing ? <Pause className="h-4 w-4 fill-current" /> : <Play className="ml-0.5 h-4 w-4 fill-current" />}
        </span>
      </button>
      <input
        type="range"
        min={0}
        max={total || 1}
        step={0.1}
        value={Math.min(time, total || 1)}
        onChange={(event) => { const audio = audioRef.current; if (audio) { audio.currentTime = Number(event.target.value); setTime(audio.currentTime); } }}
        aria-label="Position"
        aria-valuetext={`${formatClock(time)} of ${formatClock(total)}`}
        className="scrubber h-11 min-w-0 flex-1"
        style={{ ['--progress' as string]: `${total ? (Math.min(time, total) / total) * 100 : 0}%` }}
      />
      <span className="shrink-0 text-meta tabular">
        {formatClock(time)} <span className="text-text-secondary">of {formatClock(total)}</span>
      </span>
      <button type="button" onClick={cycleSpeed} aria-label={`Playback speed ${speed}×`} className="pressable inline-flex h-11 min-w-11 shrink-0 items-center justify-center rounded-full px-1 text-meta font-semibold text-accent hover:bg-fill tabular">
        {speed}×
      </button>
    </div>
  );
}
