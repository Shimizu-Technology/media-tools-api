/**
 * Auth store — helpers for API key management.
 *
 * With Clerk, auth tokens are fetched just-in-time by apiAuth.
 * This file only handles API key storage for developer/API-key flows.
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
