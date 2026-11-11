import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Check, Copy, Loader2, Search, X } from 'lucide-react';
import type { Citation, MediaSegment } from '../../lib/api';
import { formatTimestamp } from '../../lib/citations';
import { transcriptCopyText } from '../../lib/transcriptCopy';
import { Button } from '../ui/Button';
import { Input, Segmented } from '../ui/Field';

type Mode = 'readable' | 'timestamps' | 'original';

/**
 * The transcript, set for reading: generous leading, a comfortable measure, in
 * the page's own scroll. A recording opens on its timed lines, so the current
 * one can follow playback; the readable and untouched versions are one tap
 * away, and find highlights matches in place.
 */
export function TranscriptSection({ title, text, originalText, segments, onCitationClick, formatting, onFormat, formatBusy, preferTimestamps = false, activeSegment = null, playing = false }: {
  title: string;
  text: string;
  originalText?: string;
  segments: MediaSegment[];
  onCitationClick: (citation: Citation) => void;
  formatting?: { status: string; error?: string };
  onFormat?: () => void;
  formatBusy?: boolean;
  /** Open on the timed lines when there are any. */
  preferTimestamps?: boolean;
  /** The segment playing now. */
  activeSegment?: string | null;
  playing?: boolean;
}) {
  const [chosenMode, setMode] = useState<Mode | null>(null);
  const [finding, setFinding] = useState(false);
  const [query, setQuery] = useState('');
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'failed'>('idle');
  const copyResetRef = useRef<number | null>(null);
  const timed = useMemo(() => segments.filter((segment) => typeof segment.start_ms === 'number'), [segments]);
  const paged = useMemo(() => segments.filter((segment) => typeof segment.page_number === 'number'), [segments]);
  const mode: Mode = chosenMode ?? (preferTimestamps && timed.length ? 'timestamps' : 'readable');
  const original = originalText?.trim() && originalText.trim() !== text.trim() ? originalText.trim() : '';
  const readable = text.trim() || segments.map((segment) => segment.text.trim()).filter(Boolean).join('\n\n');
  const options: { value: Mode; label: string }[] = [{ value: 'readable', label: 'Readable' }];
  if (timed.length) options.push({ value: 'timestamps', label: 'Timestamps' });
  if (original) options.push({ value: 'original', label: 'Original' });

  const visibleText = mode === 'original' ? original : readable;
  const matches = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase();
    if (!needle) return 0;
    const haystack = (mode === 'timestamps' ? timed.map((segment) => segment.text).join('\n') : visibleText).toLocaleLowerCase();
    return haystack.split(needle).length - 1;
  }, [mode, query, timed, visibleText]);

  // Keep the playing line in view, but only for someone following along: if the
  // previous line has scrolled away, they are reading elsewhere.
  const followedRef = useRef<string | null>(null);
  useEffect(() => {
    const previous = followedRef.current;
    followedRef.current = activeSegment;
    if (!activeSegment || !playing || mode !== 'timestamps') return;
    const line = document.getElementById(`segment-${activeSegment}`);
    const before = previous ? document.getElementById(`segment-${previous}`)?.getBoundingClientRect() : null;
    if (!line || !before || !line.offsetParent) return;
    if (before.bottom > 0 && before.top < window.innerHeight) line.scrollIntoView({ block: 'nearest' });
  }, [activeSegment, mode, playing]);

  useEffect(() => () => {
    if (copyResetRef.current !== null) window.clearTimeout(copyResetRef.current);
  }, []);

  // One tap for the whole thing; selecting a long transcript by hand is the alternative.
  const copyAll = async () => {
    let next: 'copied' | 'failed' = 'copied';
    try {
      await navigator.clipboard.writeText(transcriptCopyText({ mode, chosen: chosenMode !== null, readable, original, segments: timed }));
    } catch {
      next = 'failed';
    }
    setCopyState(next);
    if (copyResetRef.current !== null) window.clearTimeout(copyResetRef.current);
    copyResetRef.current = window.setTimeout(() => setCopyState('idle'), 2000);
  };

  if (!readable) {
    return (
      <section aria-labelledby="transcript-heading">
        <h2 id="transcript-heading" className="sr-only">{title}</h2>
        <p className="mt-2 text-callout text-text-secondary">No text was found.</p>
      </section>
    );
  }

  return (
    <section aria-labelledby="transcript-heading">
      <h2 id="transcript-heading" className="sr-only">{title}</h2>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex min-w-0 flex-1 items-center justify-between gap-1">
          {options.length > 1 ? <Segmented label="Transcript view" value={mode} options={options} onChange={setMode} /> : <span />}
          <div className="flex shrink-0 items-center">
            <button type="button" onClick={() => void copyAll()} className="pressable inline-flex h-11 items-center gap-1.5 rounded-full px-3 text-callout font-semibold text-accent-text hover:bg-fill">
              {copyState === 'copied' ? <Check className="h-[18px] w-[18px]" aria-hidden="true" /> : <Copy className="h-[18px] w-[18px]" aria-hidden="true" />}
              {copyState === 'copied' ? 'Copied' : copyState === 'failed' ? 'Could not copy' : 'Copy all'}
            </button>
            <span className="sr-only" role="status">{copyState === 'copied' ? `Copied the ${title.toLowerCase()}` : copyState === 'failed' ? 'The browser blocked the clipboard' : ''}</span>
            <button type="button" onClick={() => { setFinding((value) => !value); setQuery(''); }} aria-label={finding ? 'Close find' : `Find in ${title.toLowerCase()}`} aria-expanded={finding} className="pressable inline-flex h-11 w-11 items-center justify-center rounded-full text-accent-text hover:bg-fill">
              {finding ? <X className="h-5 w-5" /> : <Search className="h-5 w-5" />}
            </button>
          </div>
        </div>
      </div>

      {finding && (
        <div className="relative mt-2">
          <Input type="search" autoFocus value={query} onChange={(event) => setQuery(event.target.value)} placeholder={`Find in ${title.toLowerCase()}`} aria-label={`Find in ${title.toLowerCase()}`} className="pr-24" />
          {query.trim() && <span className="absolute right-3 top-1/2 -translate-y-1/2 text-meta text-text-secondary tabular" role="status">{matches === 1 ? '1 match' : `${matches} matches`}</span>}
        </div>
      )}

      {formatting && mode === 'readable' && (formatting.status === 'pending' || formatting.status === 'processing') && (
        <p className="mt-3 flex items-center gap-2 text-callout text-text-secondary" role="status"><Loader2 className="h-4 w-4 animate-spin" />Tidying paragraphs for easier reading. The words are already here.</p>
      )}
      {formatting && mode === 'readable' && formatting.status === 'failed' && onFormat && (
        <p className="mt-3 text-callout text-text-secondary">{formatting.error || 'Readable formatting did not finish, so this is the original transcript.'} <Button variant="plain" className="-my-2 inline-flex" onClick={onFormat} busy={formatBusy}>Try again</Button></p>
      )}

      <div className="mt-3 max-w-[68ch]">
        {mode === 'timestamps' ? (
          <ol>
            {timed.map((segment) => (
              <li key={segment.id} id={`segment-${segment.id}`} aria-current={segment.id === activeSegment ? 'true' : undefined} className={`-mx-2 scroll-mb-28 scroll-mt-4 rounded-md px-2 pb-1 transition-colors first:mt-0 ${segment.id === activeSegment ? 'bg-surface-2' : ''} mt-2`}>
                <button
                  type="button"
                  onClick={() => onCitationClick({ segment_id: segment.id, item_type: segment.item_type, item_id: segment.item_id, start_ms: segment.start_ms, end_ms: segment.end_ms })}
                  className="-mx-2 -mb-2 inline-flex min-h-11 items-center rounded-sm px-2 font-mono text-meta font-semibold text-accent-text hover:bg-fill"
                  aria-label={`Play from ${formatTimestamp(segment.start_ms || 0)}`}
                >
                  {formatTimestamp(segment.start_ms || 0)}
                </button>
                <p className="text-reading">{highlight(segment.text, query)}</p>
              </li>
            ))}
          </ol>
        ) : paged.length > 1 && mode === 'readable' ? (
          paged.map((segment) => (
            <div key={segment.id} id={`segment-${segment.id}`} data-page={segment.page_number} className="mt-6 first:mt-0">
              <p className="text-meta font-semibold text-text-secondary">Page {segment.page_number}</p>
              <Paragraphs text={segment.text} query={query} />
            </div>
          ))
        ) : (
          <Paragraphs text={visibleText} query={query} />
        )}
      </div>
    </section>
  );
}

function Paragraphs({ text, query }: { text: string; query: string }) {
  const paragraphs = text.split(/\n{2,}|\n(?=\S)/).map((part) => part.trim()).filter(Boolean);
  return <>{paragraphs.map((paragraph, index) => <p key={index} className="mt-4 text-reading first:mt-1">{highlight(paragraph, query)}</p>)}</>;
}

function highlight(text: string, query: string): ReactNode {
  const needle = query.trim();
  if (!needle) return text;
  const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return text.split(new RegExp(`(${escaped})`, 'gi')).map((part, index) => (part.toLocaleLowerCase() === needle.toLocaleLowerCase() ? <mark key={index}>{part}</mark> : part));
}
