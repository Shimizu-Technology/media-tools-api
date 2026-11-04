import { useId, useMemo } from 'react';
import { sampleWaveform } from '../../lib/waveform';

const BAR_PITCH = 3;
const VIEW_HEIGHT = 100;
// A silent stretch still draws a dot, so the bars read as a timeline.
const MIN_HEIGHT = 5;

/**
 * Real audio peaks as rounded bars that blend from amber to coral across the
 * recording. `progress` splits played from unplayed; 1 is a fully colored row
 * thumbnail, 0 an item still processing. The bars are one path each, so moving
 * the playhead only moves a clip edge.
 */
export function Waveform({ peaks, bars, progress = 1, className = '' }: { peaks: readonly number[]; bars: number; progress?: number; className?: string }) {
  const id = useId().replace(/[^a-zA-Z0-9]/g, '');
  const path = useMemo(() => {
    const samples = sampleWaveform(peaks, bars);
    return { width: Math.max(1, samples.length) * BAR_PITCH, d: samples.map((value, index) => {
      const height = Math.max(MIN_HEIGHT, (value / 100) * VIEW_HEIGHT);
      return `M${index * BAR_PITCH + BAR_PITCH / 2} ${(VIEW_HEIGHT - height) / 2}v${height}`;
    }).join('') };
  }, [bars, peaks]);
  const played = Math.min(1, Math.max(0, progress)) * path.width;

  return (
    <svg viewBox={`0 0 ${path.width} ${VIEW_HEIGHT}`} preserveAspectRatio="none" aria-hidden="true" focusable="false" className={`block ${className}`}>
      <defs>
        <linearGradient id={`${id}g`} gradientUnits="userSpaceOnUse" x1="0" y1="0" x2={path.width} y2="0">
          <stop offset="0" style={{ stopColor: 'var(--color-waveform-start)' }} />
          <stop offset="1" style={{ stopColor: 'var(--color-waveform-end)' }} />
        </linearGradient>
        <clipPath id={`${id}c`}><rect x="0" y="0" width={played} height={VIEW_HEIGHT} /></clipPath>
      </defs>
      <path d={path.d} fill="none" strokeWidth="2" strokeLinecap="round" vectorEffect="non-scaling-stroke" style={{ stroke: 'var(--color-waveform-unplayed)' }} />
      {played > 0 && <path d={path.d} fill="none" stroke={`url(#${id}g)`} strokeWidth="2" strokeLinecap="round" vectorEffect="non-scaling-stroke" clipPath={`url(#${id}c)`} />}
    </svg>
  );
}
