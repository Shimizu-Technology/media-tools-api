import { beforeEach, describe, expect, it } from 'vitest';
import { aiConsentStorageKey, readAIConsent, writeAIConsent } from './aiConsentStorage';

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

describe('AI consent storage', () => {
  it('keeps each account\'s permission separate', () => {
    writeAIConsent('user-1', true);
    expect(readAIConsent('user-1')).toBe(true);
    expect(readAIConsent('user-2')).toBe(false);
    expect(localStorage.getItem(aiConsentStorageKey('user-1'))).toBe('granted');
  });

  it('revoking removes the stored grant', () => {
    writeAIConsent('user-1', true);
    writeAIConsent('user-1', false);
    expect(readAIConsent('user-1')).toBe(false);
    expect(localStorage.getItem(aiConsentStorageKey('user-1'))).toBeNull();
  });
});
