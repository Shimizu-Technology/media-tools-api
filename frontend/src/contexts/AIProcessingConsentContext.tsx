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

const CONSENT_KEY_PREFIX = 'mta_ai_processing_consent:v1:';

function storageKey(ownerID: string): string {
  return `${CONSENT_KEY_PREFIX}${encodeURIComponent(ownerID)}`;
}

function readConsent(ownerID: string): boolean {
  try {
    return localStorage.getItem(storageKey(ownerID)) === 'granted';
  } catch {
    return false;
  }
}

function writeConsent(ownerID: string, granted: boolean): void {
  try {
    if (granted) localStorage.setItem(storageKey(ownerID), 'granted');
    else localStorage.removeItem(storageKey(ownerID));
  } catch {
    // A blocked storage API means permission lasts only for this page session.
  }
}

export function AIProcessingConsentProvider({ ownerID, children }: { ownerID: string | null; children: ReactNode }) {
  return <AIProcessingConsentSession key={ownerID ?? 'no-owner'} ownerID={ownerID}>{children}</AIProcessingConsentSession>;
}

function AIProcessingConsentSession({ ownerID, children }: { ownerID: string | null; children: ReactNode }) {
  const [hasConsent, setHasConsent] = useState(() => ownerID ? readConsent(ownerID) : false);
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
    writeConsent(ownerID, true);
    setHasConsent(true);
    setIsOpen(false);
    settlePending(true);
  }, [ownerID, settlePending]);

  const decline = useCallback(() => {
    setIsOpen(false);
    settlePending(false);
  }, [settlePending]);

  const revokeConsent = useCallback(() => {
    if (ownerID) writeConsent(ownerID, false);
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
    <div className="fixed inset-0 z-[100] flex items-end justify-center p-4 backdrop-blur-sm sm:items-center" style={{ backgroundColor: 'var(--color-modal-scrim)' }} role="presentation">
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="ai-processing-title"
        aria-describedby="ai-processing-description"
        className="w-full max-w-xl rounded-[2rem] border p-6 shadow-2xl sm:p-8"
        style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}
      >
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
          <BrainCircuit className="h-6 w-6" />
        </div>
        <h2 id="ai-processing-title" className="mt-5 text-2xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>
          Allow third-party AI processing?
        </h2>
        <div id="ai-processing-description" className="mt-3 space-y-4 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
          <p>
            Only when you choose an AI feature, Media Tools sends the content needed for that request to these providers:
          </p>
          <ul className="space-y-3">
            <li className="flex gap-3">
              <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
              <span><strong style={{ color: 'var(--color-text-primary)' }}>OpenAI</strong> receives audio for transcription and may process text if the primary AI route is unavailable.</span>
            </li>
            <li className="flex gap-3">
              <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
              <span><strong style={{ color: 'var(--color-text-primary)' }}>OpenRouter and its selected model provider</strong> receive transcript or document text and chat prompts for readable formatting, summaries, and answers. Requests require zero-data-retention providers.</span>
            </li>
          </ul>
          <p>
            API content is not used to train OpenAI models by default. You can revoke this permission for future requests in Settings. Existing processing may finish.
          </p>
          <a href="/privacy#ai-processing" target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center gap-2 font-semibold underline" style={{ color: 'var(--color-brand-500)' }}>
            Read AI and privacy details <ExternalLink className="h-4 w-4" />
          </a>
        </div>
        <div className="mt-6 grid gap-3 sm:grid-cols-2">
          <button type="button" onClick={onDecline} className="min-h-12 rounded-xl border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
            Not now
          </button>
          <button type="button" onClick={onAllow} autoFocus className="min-h-12 rounded-xl px-4 text-sm font-semibold" style={{ backgroundColor: 'var(--color-brand-500)', color: 'var(--color-on-brand)' }}>
            Allow AI processing
          </button>
        </div>
      </section>
    </div>
  );
}
