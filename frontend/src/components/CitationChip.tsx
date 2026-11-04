import { BookOpen, Clock3, FileText } from 'lucide-react';
import type { Citation } from '../lib/api';
import { formatTimestamp } from '../lib/citations';

export function CitationChip({ citation, onClick }: {
  citation: Citation;
  onClick: (citation: Citation) => void;
}) {
  const timed = typeof citation.start_ms === 'number';
  const paged = typeof citation.page_number === 'number';
  const Icon = timed ? Clock3 : paged ? BookOpen : FileText;
  const label = timed
    ? formatTimestamp(citation.start_ms || 0)
    : paged
      ? `Page ${citation.page_number}`
      : citation.item_title || 'Source';

  return (
    <button
      type="button"
      onClick={() => onClick(citation)}
      title={citation.item_title ? `Open source: ${citation.item_title}` : 'Open source evidence'}
      className="inline-flex min-h-11 items-center gap-1.5 rounded-full border px-2.5 text-xs font-semibold transition-colors hover:bg-[var(--color-accent-tint)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-accent)]"
      style={{ borderColor: 'var(--color-separator)', color: 'var(--color-accent)', backgroundColor: 'var(--color-fill)' }}
    >
      <Icon className="h-3.5 w-3.5" />
      {label}
    </button>
  );
}

export function CitationRow({ citations, onClick }: {
  citations?: Citation[];
  onClick: (citation: Citation) => void;
}) {
  if (!citations?.length) return null;
  return (
    <div className="mt-2 flex flex-wrap gap-1.5" aria-label="Source citations">
      {citations.map((citation) => (
        <CitationChip key={citation.segment_id} citation={citation} onClick={onClick} />
      ))}
    </div>
  );
}
