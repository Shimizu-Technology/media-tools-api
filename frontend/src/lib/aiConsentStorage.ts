const CONSENT_KEY_PREFIX = 'mta_ai_processing_consent:v1:';

export function aiConsentStorageKey(ownerID: string): string {
  return `${CONSENT_KEY_PREFIX}${encodeURIComponent(ownerID)}`;
}

export function readAIConsent(ownerID: string): boolean {
  try { return localStorage.getItem(aiConsentStorageKey(ownerID)) === 'granted'; } catch { return false; }
}

export function writeAIConsent(ownerID: string, granted: boolean): void {
  try {
    if (granted) localStorage.setItem(aiConsentStorageKey(ownerID), 'granted');
    else localStorage.removeItem(aiConsentStorageKey(ownerID));
  } catch {
    // A blocked storage API means permission lasts only for this page session.
  }
}
