import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { ExternalLink } from 'lucide-react';
import { Dialog } from '../components/ui/Dialog';
import { Button } from '../components/ui/Button';
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
  // A native modal dialog, so it stays usable on top of another open sheet.
  return (
    <Dialog
      open
      onClose={onDecline}
      title="Allow third-party AI processing?"
      footer={(
        <div className="grid gap-2 sm:grid-cols-2">
          <Button onClick={onDecline}>Not now</Button>
          <Button variant="primary" onClick={onAllow} autoFocus>Allow AI processing</Button>
        </div>
      )}
    >
      <div id="ai-processing-description" className="space-y-4 text-callout text-text-secondary">
        <p>
          With automatic transcription on, new recordings go to OpenAI when they are saved, and their transcripts go to OpenRouter. Everything else is sent only when you use an AI feature. Media Tools sends the content needed to these providers:
        </p>
        <ul className="list-disc space-y-3 pl-5">
          <li><strong className="text-text">OpenAI</strong> receives audio for transcription and may process text if the primary AI route is unavailable.</li>
          <li><strong className="text-text">OpenRouter and its selected model provider</strong> receive transcript or document text and chat prompts for readable formatting, summaries, and answers. Requests require zero-data-retention providers.</li>
        </ul>
        <p>
          API content is not used to train OpenAI models by default. You can revoke this permission for future requests in Settings. Existing processing may finish.
        </p>
        <a href="/privacy#ai-processing" target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center gap-1.5 font-semibold text-accent-text underline">
          Read AI and privacy details <ExternalLink className="h-4 w-4" aria-hidden="true" />
        </a>
      </div>
    </Dialog>
  );
}
