import { useState } from 'react';
import { Flag } from 'lucide-react';
import {
  getErrorMessage,
  reportAIContent,
  type AIContentReportCategory,
  type AIContentReportTargetType,
} from '../lib/api';
import { Dialog } from './ui/Dialog';
import { Button } from './ui/Button';
import { Notice, TextArea } from './ui/Field';

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

/** Lets a user report one AI output without leaving Media Tools. */
export function AIContentReportButton({ targetType, targetId, label = 'Report AI output' }: AIContentReportButtonProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [category, setCategory] = useState<AIContentReportCategory>('dangerous');
  const [details, setDetails] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState('');

  const open = () => {
    setSubmitted(false);
    setError('');
    setIsOpen(true);
  };

  const close = () => {
    if (!isSubmitting) setIsOpen(false);
  };

  const submit = async () => {
    setIsSubmitting(true);
    setError('');
    try {
      await reportAIContent({ targetType, targetId, category, details: details.trim() });
      setSubmitted(true);
    } catch (err) {
      setError(getErrorMessage(err) || 'The report could not be saved. Try again.');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <>
      <button type="button" onClick={open} className="pressable -ml-2 inline-flex min-h-11 items-center gap-1.5 rounded-sm px-2 text-meta font-medium text-text-secondary hover:bg-fill">
        <Flag className="h-3.5 w-3.5" aria-hidden="true" />
        {label}
      </button>

      <Dialog
        open={isOpen}
        onClose={close}
        title={submitted ? 'Report received' : 'Report this AI output'}
        footer={submitted ? (
          <Button variant="primary" block onClick={close}>Done</Button>
        ) : (
          <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <Button onClick={close} disabled={isSubmitting}>Cancel</Button>
            <Button variant="primary" onClick={() => void submit()} busy={isSubmitting}>Send report</Button>
          </div>
        )}
      >
        {submitted ? (
          <p className="text-callout text-text-secondary" role="status">Shimizu Technology can now review this output and use the report to improve safeguards.</p>
        ) : (
          <div className="space-y-4">
            <p className="text-callout text-text-secondary">
              The selected AI output, category, and optional note will be available to Shimizu Technology for review. Media Tools does not attach a separate copy of your source recording, transcript, or document.
            </p>
            <div>
              <label className="block text-callout font-semibold" htmlFor={`ai-report-category-${targetId}`}>What is wrong with it?</label>
              <select
                id={`ai-report-category-${targetId}`}
                value={category}
                onChange={(event) => setCategory(event.target.value as AIContentReportCategory)}
                className="mt-2 min-h-11 w-full rounded-md border border-separator bg-surface px-3 text-text outline-none focus:border-accent-text"
              >
                {categories.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
              </select>
            </div>
            <div>
              <label className="block text-callout font-semibold" htmlFor={`ai-report-details-${targetId}`}>Note <span className="font-normal text-text-secondary">(optional)</span></label>
              <TextArea
                id={`ai-report-details-${targetId}`}
                value={details}
                onChange={(event) => setDetails(event.target.value)}
                maxLength={1000}
                rows={4}
                placeholder="Tell us what concerned you. Do not add passwords, API keys, or source content."
                className="mt-2 resize-y"
              />
              <p className="mt-1 text-right text-meta text-text-secondary tabular">{details.length}/1000</p>
            </div>
            {error && <Notice tone="error">{error}</Notice>}
          </div>
        )}
      </Dialog>
    </>
  );
}
