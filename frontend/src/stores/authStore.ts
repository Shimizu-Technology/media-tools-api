/**
 * Auth store — helpers for API key management.
 *
 * Browser sessions use HttpOnly cookies. This file only handles the API key
 * storage used by local API-key development mode.
 */

const API_KEY_STORAGE_KEY = 'mta_api_key';

/** Get stored API key. */
export function getStoredAPIKey(): string | null {
  return localStorage.getItem(API_KEY_STORAGE_KEY);
}

export function setStoredAPIKey(key: string): void {
  localStorage.setItem(API_KEY_STORAGE_KEY, key);
}

export function clearStoredAPIKey(): void {
  localStorage.removeItem(API_KEY_STORAGE_KEY);
}
