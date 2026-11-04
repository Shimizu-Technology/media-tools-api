import { useEffect, useRef, useState } from 'react';
import { motion } from 'framer-motion';
import { AIContentReportButton } from '../AIContentReportButton';
import { CitationRow } from '../CitationChip';
import { Button } from '../ui/Button';
import { Notice } from '../ui/Field';
import { getSummaryErrorMessage, type AIContentReportTargetType, type Citation, type SummaryEvidence } from '../../lib/api';

export type SummaryView = {
  status: 'none' | 'pending' | 'processing' | 'completed' | 'failed';
  text: string;
  keyPoints: string[];
  actionItems: string[];
  decisions: string[];
  evidence?: SummaryEvidence;
  errorMessage?: string;
  reportTarget?: { type: AIContentReportTargetType; id: string };
};

/**
 * The summary comes first. While it is being written the section says so,
 * after a reload too, and it keeps waiting however long that takes.
 */
export function SummarySection({ summary, onSummarize, busy, onCitationClick, automaticSummaries }: {
  summary: SummaryView;
  onSummarize: () => void;
  busy: boolean;
  onCitationClick: (citation: Citation) => void;
  /** The account summarizes new transcripts by itself. */
  automaticSummaries?: boolean;
}) {
  const pending = summary.status === 'pending' || summary.status === 'processing';
  // Fade the summary in only when it arrives while the page is open.
  const wasPendingRef = useRef(pending);
  const [arrived, setArrived] = useState(false);
  useEffect(() => {
    if (wasPendingRef.current && summary.status === 'completed') queueMicrotask(() => setArrived(true));
    wasPendingRef.current = pending;
  }, [pending, summary.status]);

  const hasSummary = summary.status === 'completed' && Boolean(summary.text.trim() || summary.keyPoints.length);

  return (
    <section aria-labelledby="summary-heading" className="mt-7">
      <h2 id="summary-heading" className="text-heading">Summary</h2>
      {pending && (
        <div className="mt-3" role="status" aria-live="polite">
          <p className="text-callout text-text-secondary">Writing the summary. It appears here when it is ready, even if you leave and come back.</p>
          <div className="mt-3 space-y-2.5" aria-hidden="true">
            <div className="h-3.5 w-full animate-pulse rounded-sm bg-fill" />
            <div className="h-3.5 w-11/12 animate-pulse rounded-sm bg-fill" />
            <div className="h-3.5 w-3/4 animate-pulse rounded-sm bg-fill" />
          </div>
        </div>
      )}
      {summary.status === 'failed' && (
        <div className="mt-3">
          <Notice tone="error" action={<Button variant="plain" onClick={onSummarize} busy={busy}>Try again</Button>}>
            The summary could not be written. {getSummaryErrorMessage(summary.errorMessage)}
          </Notice>
        </div>
      )}
      {summary.status === 'none' && (
        <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1">
          <p className="text-callout text-text-secondary">{automaticSummaries === false ? 'Automatic summaries are off for this account.' : 'No summary yet.'}</p>
          <Button variant="plain" className="-ml-4 sm:ml-0" onClick={onSummarize} busy={busy}>Summarize</Button>
        </div>
      )}
      {hasSummary && (
        <motion.div initial={arrived ? { opacity: 0 } : false} animate={{ opacity: 1 }} transition={{ duration: 0.24, ease: [0.23, 1, 0.32, 1] }}>
          {summary.text.trim() && (
            <div className="mt-2">
              {summary.text.trim().split(/\n{2,}/).map((paragraph, index) => <p key={index} className="mt-2 max-w-[68ch] text-reading first:mt-0">{paragraph}</p>)}
              <CitationRow citations={summary.evidence?.summary} onClick={onCitationClick} />
            </div>
          )}
          <SummaryList title="Key points" items={summary.keyPoints} citations={summary.evidence?.key_points} onCitationClick={onCitationClick} />
          <SummaryList title="Decisions" items={summary.decisions} citations={summary.evidence?.decisions} onCitationClick={onCitationClick} />
          <SummaryList title="Follow-ups" items={summary.actionItems} citations={summary.evidence?.action_items} onCitationClick={onCitationClick} />
          {summary.reportTarget && <div className="mt-2"><AIContentReportButton targetType={summary.reportTarget.type} targetId={summary.reportTarget.id} label="Report summary" /></div>}
        </motion.div>
      )}
    </section>
  );
}

function SummaryList({ title, items, citations, onCitationClick }: { title: string; items: string[]; citations?: Citation[][]; onCitationClick: (citation: Citation) => void }) {
  if (!items?.length) return null;
  return (
    <div className="mt-5">
      <h3 className="text-subheading">{title}</h3>
      <ul className="mt-1.5 max-w-[68ch] list-disc space-y-1.5 pl-5 text-reading marker:text-text-secondary">
        {items.map((item, index) => (
          <li key={`${title}-${index}`}>
            {item}
            <CitationRow citations={citations?.[index]} onClick={onCitationClick} />
          </li>
        ))}
      </ul>
    </div>
  );
}
