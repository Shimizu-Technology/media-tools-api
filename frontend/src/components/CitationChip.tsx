import { BookOpen, Clock3, FileText } from 'lucide-react';
import type { Citation } from '../lib/api';
import { formatTimestamp } from '../lib/citations';

/** A source reference: small in the text, 44px to touch. */
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
      className="pressable group -my-2.5 inline-flex min-h-11 items-center"
    >
      <span className="inline-flex items-center gap-1 rounded-full bg-accent-tint px-2 py-0.5 font-sans text-meta font-semibold text-accent tabular group-hover:bg-fill">
        <Icon className="h-3 w-3" aria-hidden="true" />
        {label}
      </span>
    </button>
  );
}

export function CitationRow({ citations, onClick }: {
  citations?: Citation[];
  onClick: (citation: Citation) => void;
}) {
  if (!citations?.length) return null;
  return (
    <span className="mt-1 flex flex-wrap gap-x-1.5" aria-label="Sources">
      {citations.map((citation) => (
        <CitationChip key={citation.segment_id} citation={citation} onClick={onClick} />
      ))}
    </span>
  );
}
