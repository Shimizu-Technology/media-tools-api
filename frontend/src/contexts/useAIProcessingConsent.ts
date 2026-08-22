import { useContext } from 'react';
import { AIProcessingConsentContext, type AIProcessingConsentContextValue } from './aiProcessingConsentValue';

export function useAIProcessingConsent(): AIProcessingConsentContextValue {
  const value = useContext(AIProcessingConsentContext);
  if (!value) throw new Error('useAIProcessingConsent must be used within AIProcessingConsentProvider');
  return value;
}
