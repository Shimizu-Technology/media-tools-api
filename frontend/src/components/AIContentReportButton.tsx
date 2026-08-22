import { useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { AlertCircle, CheckCircle2, Flag, Loader2, X } from 'lucide-react';
import {
  reportAIContent,
  type AIContentReportCategory,
  type AIContentReportTargetType,
} from '../lib/api';

interface AIContentReportButtonProps {
  targetType: AIContentReportTargetType;
  targetId: string;
  label?: string;
}

const categories: Array<{ value: AIContentReportCategory; label: string }> = [
  { value: 'dangerous', label: 'Dangerous or illegal' },
  { value: 'hate_or_harassment', label: 'Hate or harassment' },
  { value: 'sexual', label: 'Sexual content' },
  { value: 'privacy', label: 'Privacy concern' },
  { value: 'deceptive', label: 'Deceptive or inaccurate' },
  { value: 'other', label: 'Something else' },
];

/** Lets a user report one selected AI output without leaving Media Tools. */
export function AIContentReportButton({
  targetType,
  targetId,
  label = 'Report AI output',
}: AIContentReportButtonProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [category, setCategory] = useState<AIContentReportCategory>('dangerous');
  const [details, setDetails] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState('');
  const triggerRef = useRef<HTMLButtonElement | null>(null);

  const open = () => {
    setSubmitted(false);
    setError('');
    setIsOpen(true);
  };

  const close = () => {
    if (!isSubmitting) {
      setIsOpen(false);
      window.requestAnimationFrame(() => triggerRef.current?.focus());
    }
  };

  const submit = async () => {
    setIsSubmitting(true);
    setError('');
    try {
      await reportAIContent({ targetType, targetId, category, details: details.trim() });
      setSubmitted(true);
    } catch (err: unknown) {
      const apiError = err as { message?: string };
      setError(apiError.message || 'The report could not be saved. Please try again.');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        onClick={open}
        className="inline-flex min-h-11 items-center gap-2 rounded-lg px-2.5 text-xs font-semibold transition hover:bg-[var(--color-nav-hover)]"
        style={{ color: 'var(--color-text-muted)' }}
      >
        <Flag className="h-3.5 w-3.5" />
        {label}
      </button>

      {isOpen && createPortal((
        <div
          className="fixed inset-0 z-50 flex items-end justify-center p-0 sm:items-center sm:p-6"
          style={{ backgroundColor: 'var(--color-modal-scrim)' }}
          onKeyDown={(event) => {
            if (event.key === 'Escape') close();
          }}
        >
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="ai-report-title"
            className="max-h-[92vh] w-full max-w-lg overflow-y-auto rounded-t-3xl border p-5 shadow-2xl sm:rounded-3xl sm:p-6"
            style={{
              backgroundColor: 'var(--color-surface-elevated)',
              borderColor: 'var(--color-border)',
            }}
          >
            <div className="flex items-start justify-between gap-4">
              <div>
                <p className="text-xs font-semibold uppercase tracking-[0.16em]" style={{ color: 'var(--color-brand-500)' }}>
                  Safety report
                </p>
                <h2 id="ai-report-title" className="mt-2 text-xl font-semibold">
                  Report this AI output
                </h2>
              </div>
              <button
                type="button"
                onClick={close}
                aria-label="Close report"
                className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl"
                style={{ color: 'var(--color-text-muted)' }}
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            {submitted ? (
              <div className="py-8 text-center" role="status">
                <CheckCircle2 className="mx-auto h-10 w-10" style={{ color: 'var(--color-success)' }} />
                <h3 className="mt-4 font-semibold">Report received</h3>
                <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
                  Shimizu Technology can now review this output and use the report to improve safeguards.
                </p>
                <button
                  type="button"
                  onClick={close}
                  className="mt-6 min-h-11 rounded-xl px-5 text-sm font-semibold"
                  style={{ backgroundColor: 'var(--color-brand-500)', color: 'var(--color-on-brand)' }}
                >
                  Done
                </button>
              </div>
            ) : (
              <>
                <p className="mt-4 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
                  The selected AI output, category, and optional note will be available to Shimizu Technology for review. Media Tools does not attach a separate copy of your source recording, transcript, or document.
                </p>

                <label className="mt-5 block text-sm font-semibold" htmlFor={`ai-report-category-${targetId}`}>
                  What is wrong with it?
                </label>
                <select
                  id={`ai-report-category-${targetId}`}
                  value={category}
                  onChange={(event) => setCategory(event.target.value as AIContentReportCategory)}
                  autoFocus
                  className="mt-2 min-h-11 w-full rounded-xl border px-3 text-sm outline-none"
                  style={{
                    backgroundColor: 'var(--color-surface)',
                    borderColor: 'var(--color-border)',
                    color: 'var(--color-text-primary)',
                  }}
                >
                  {categories.map((option) => (
                    <option key={option.value} value={option.value}>{option.label}</option>
                  ))}
                </select>

                <label className="mt-5 block text-sm font-semibold" htmlFor={`ai-report-details-${targetId}`}>
                  Note <span className="font-normal" style={{ color: 'var(--color-text-muted)' }}>(optional)</span>
                </label>
                <textarea
                  id={`ai-report-details-${targetId}`}
                  value={details}
                  onChange={(event) => setDetails(event.target.value)}
                  maxLength={1000}
                  rows={4}
                  placeholder="Tell us what concerned you. Do not add passwords, API keys, or source content."
                  className="mt-2 w-full resize-y rounded-xl border p-3 text-base outline-none sm:text-sm"
                  style={{
                    backgroundColor: 'var(--color-surface)',
                    borderColor: 'var(--color-border)',
                    color: 'var(--color-text-primary)',
                  }}
                />
                <p className="mt-1 text-right text-xs" style={{ color: 'var(--color-text-muted)' }}>
                  {details.length}/1000
                </p>

                {error && (
                  <div className="mt-4 flex items-start gap-2 rounded-xl border p-3 text-sm" role="alert" style={{ borderColor: 'var(--color-danger)', color: 'var(--color-danger)' }}>
                    <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
                    {error}
                  </div>
                )}

                <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
                  <button
                    type="button"
                    onClick={close}
                    disabled={isSubmitting}
                    className="min-h-11 rounded-xl border px-4 text-sm font-semibold disabled:opacity-50"
                    style={{ borderColor: 'var(--color-border)' }}
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    onClick={() => void submit()}
                    disabled={isSubmitting}
                    className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 text-sm font-semibold disabled:opacity-50"
                    style={{ backgroundColor: 'var(--color-brand-500)', color: 'var(--color-on-brand)' }}
                  >
                    {isSubmitting && <Loader2 className="h-4 w-4 animate-spin" />}
                    Submit report
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      ), document.body)}
    </>
  );
}
