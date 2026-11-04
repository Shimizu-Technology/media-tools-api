import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { BrainCircuit, ExternalLink, ShieldCheck } from 'lucide-react';
import { AIProcessingConsentContext } from './aiProcessingConsentValue';
import { readAIConsent, writeAIConsent } from '../lib/aiConsentStorage';

export function AIProcessingConsentProvider({ ownerID, children }: { ownerID: string | null; children: ReactNode }) {
  return <AIProcessingConsentSession key={ownerID ?? 'no-owner'} ownerID={ownerID}>{children}</AIProcessingConsentSession>;
}

function AIProcessingConsentSession({ ownerID, children }: { ownerID: string | null; children: ReactNode }) {
  const [hasConsent, setHasConsent] = useState(() => ownerID ? readAIConsent(ownerID) : false);
  const [isOpen, setIsOpen] = useState(false);
  const pendingResolvers = useRef<Array<(granted: boolean) => void>>([]);

  const settlePending = useCallback((granted: boolean) => {
    const resolvers = pendingResolvers.current;
    pendingResolvers.current = [];
    resolvers.forEach((resolve) => resolve(granted));
  }, []);

  useEffect(() => () => {
    const resolvers = pendingResolvers.current;
    pendingResolvers.current = [];
    resolvers.forEach((resolve) => resolve(false));
  }, []);

  const requestConsent = useCallback(async () => {
    if (!ownerID) return false;
    if (hasConsent) return true;
    setIsOpen(true);
    return await new Promise<boolean>((resolve) => {
      pendingResolvers.current.push(resolve);
    });
  }, [hasConsent, ownerID]);

  const allow = useCallback(() => {
    if (!ownerID) {
      settlePending(false);
      setIsOpen(false);
      return;
    }
    writeAIConsent(ownerID, true);
    setHasConsent(true);
    setIsOpen(false);
    settlePending(true);
  }, [ownerID, settlePending]);

  const decline = useCallback(() => {
    setIsOpen(false);
    settlePending(false);
  }, [settlePending]);

  const revokeConsent = useCallback(() => {
    if (ownerID) writeAIConsent(ownerID, false);
    setHasConsent(false);
  }, [ownerID]);

  const value = useMemo(() => ({ hasConsent, requestConsent, revokeConsent }), [hasConsent, requestConsent, revokeConsent]);

  return (
    <AIProcessingConsentContext.Provider value={value}>
      {children}
      {isOpen && <AIProcessingDisclosureDialog onAllow={allow} onDecline={decline} />}
    </AIProcessingConsentContext.Provider>
  );
}

function AIProcessingDisclosureDialog({ onAllow, onDecline }: { onAllow: () => void; onDecline: () => void }) {
  return (
    <div className="fixed inset-0 z-[100] flex items-end justify-center p-4 backdrop-blur-sm sm:items-center" style={{ backgroundColor: 'var(--color-scrim)' }} role="presentation">
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="ai-processing-title"
        aria-describedby="ai-processing-description"
        className="w-full max-w-xl rounded-xl border p-6 shadow-overlay sm:p-8"
        style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-separator)' }}
      >
        <div className="flex h-12 w-12 items-center justify-center rounded-lg" style={{ backgroundColor: 'var(--color-accent-tint)', color: 'var(--color-accent)' }}>
          <BrainCircuit className="h-6 w-6" />
        </div>
        <h2 id="ai-processing-title" className="mt-5 text-2xl font-semibold" style={{ color: 'var(--color-text)' }}>
          Allow third-party AI processing?
        </h2>
        <div id="ai-processing-description" className="mt-3 space-y-4 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
          <p>
            With automatic transcription on, new recordings go to OpenAI when they are saved, and their transcripts go to OpenRouter. Everything else is sent only when you use an AI feature. Media Tools sends the content needed to these providers:
          </p>
          <ul className="space-y-3">
            <li className="flex gap-3">
              <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-accent)' }} />
              <span><strong style={{ color: 'var(--color-text)' }}>OpenAI</strong> receives audio for transcription and may process text if the primary AI route is unavailable.</span>
            </li>
            <li className="flex gap-3">
              <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-accent)' }} />
              <span><strong style={{ color: 'var(--color-text)' }}>OpenRouter and its selected model provider</strong> receive transcript or document text and chat prompts for readable formatting, summaries, and answers. Requests require zero-data-retention providers.</span>
            </li>
          </ul>
          <p>
            API content is not used to train OpenAI models by default. You can revoke this permission for future requests in Settings. Existing processing may finish.
          </p>
          <a href="/privacy#ai-processing" target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center gap-2 font-semibold underline" style={{ color: 'var(--color-accent)' }}>
            Read AI and privacy details <ExternalLink className="h-4 w-4" />
          </a>
        </div>
        <div className="mt-6 grid gap-3 sm:grid-cols-2">
          <button type="button" onClick={onDecline} className="min-h-12 rounded-md border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-separator)', color: 'var(--color-text)' }}>
            Not now
          </button>
          <button type="button" onClick={onAllow} autoFocus className="min-h-12 rounded-md px-4 text-sm font-semibold" style={{ backgroundColor: 'var(--color-accent-fill)', color: 'var(--color-on-accent)' }}>
            Allow AI processing
          </button>
        </div>
      </section>
    </div>
  );
}
