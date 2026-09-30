import { beforeEach, describe, expect, it } from 'vitest';
import { aiConsentStorageKey, migrateAIConsentToStableUser } from './aiConsentStorage';

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() { return values.size; },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => { values.delete(key); },
    setItem: (key, value) => { values.set(key, value); },
  };
}

beforeEach(() => {
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: memoryStorage() });
});

describe('AI consent identity migration', () => {
  it('moves a verified Clerk grant to the stable application user', () => {
    localStorage.setItem(aiConsentStorageKey('clerk_alice'), 'granted');
    expect(migrateAIConsentToStableUser({ stableUserID: 'user-1', linkedClerkID: 'clerk_alice', activeClerkID: 'clerk_alice' })).toBe(true);
    expect(localStorage.getItem(aiConsentStorageKey('user-1'))).toBe('granted');
    expect(localStorage.getItem(aiConsentStorageKey('clerk_alice'))).toBeNull();
  });

  it('does not move a grant across a Clerk account mismatch', () => {
    localStorage.setItem(aiConsentStorageKey('clerk_alice'), 'granted');
    expect(migrateAIConsentToStableUser({ stableUserID: 'user-1', linkedClerkID: 'clerk_alice', activeClerkID: 'clerk_bob' })).toBe(false);
    expect(localStorage.getItem(aiConsentStorageKey('user-1'))).toBeNull();
    expect(localStorage.getItem(aiConsentStorageKey('clerk_alice'))).toBe('granted');
  });
});
