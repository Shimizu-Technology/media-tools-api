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

export function migrateAIConsentToStableUser({
  stableUserID,
  linkedClerkID,
  activeClerkID,
}: {
  stableUserID: string;
  linkedClerkID: string;
  activeClerkID: string | null;
}): boolean {
  if (!stableUserID || !linkedClerkID || stableUserID === linkedClerkID) return false;
  // When Clerk is active, its verified subject must match the subject linked
  // to this cookie-session user. Never copy an account-scoped permission
  // merely because both identities happen to exist in the same browser.
  if (activeClerkID && activeClerkID !== linkedClerkID) return false;
  try {
    const oldKey = aiConsentStorageKey(linkedClerkID);
    const newKey = aiConsentStorageKey(stableUserID);
    if (localStorage.getItem(oldKey) !== 'granted') return false;
    localStorage.setItem(newKey, 'granted');
    if (localStorage.getItem(newKey) !== 'granted') return false;
    localStorage.removeItem(oldKey);
    return true;
  } catch {
    return false;
  }
}
