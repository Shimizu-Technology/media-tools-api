import type { MediaSegment } from './api';
import { formatTimestamp } from './citations';

/**
 * What Copy all hands over: the view on screen. Timed lines carry their stamps
 * only when someone picked that view; a recording opens on them, but most
 * people pasting a transcript want the plain words.
 */
export function transcriptCopyText({ mode, chosen, readable, original, segments }: {
  mode: 'readable' | 'timestamps' | 'original';
  chosen: boolean;
  readable: string;
  original: string;
  segments: MediaSegment[];
}): string {
  if (mode === 'original') return original;
  if (mode === 'timestamps' && chosen) {
    const stamped = segments
      .filter((segment) => typeof segment.start_ms === 'number' && segment.text.trim())
      .map((segment) => `[${formatTimestamp(segment.start_ms || 0)}] ${segment.text.trim()}`)
      .join('\n');
    if (stamped) return stamped;
  }
  return readable;
}
