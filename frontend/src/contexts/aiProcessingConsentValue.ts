import { createContext } from 'react';

export interface AIProcessingConsentContextValue {
  hasConsent: boolean;
  requestConsent: () => Promise<boolean>;
  revokeConsent: () => void;
}

export const AIProcessingConsentContext = createContext<AIProcessingConsentContextValue | null>(null);
