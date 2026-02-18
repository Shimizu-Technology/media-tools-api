/**
 * Auth store — legacy helpers for API key management.
 *
 * With Clerk, auth tokens are managed via AuthContext + apiAuth.ts.
 * This file only handles API key storage for backward compatibility.
 */

const API_KEY_STORAGE_KEY = 'mta_api_key';

/** Get stored API key for backward compat. */
export function getStoredAPIKey(): string | null {
  return localStorage.getItem(API_KEY_STORAGE_KEY);
}

export function setStoredAPIKey(key: string): void {
  localStorage.setItem(API_KEY_STORAGE_KEY, key);
}

export function clearStoredAPIKey(): void {
  localStorage.removeItem(API_KEY_STORAGE_KEY);
}

/**
 * Synchronous auth headers (legacy — uses stored tokens/keys).
 * Prefer getAuthHeadersAsync() from lib/apiAuth.ts for new code.
 */
export function getAuthHeaders(): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };

  const token = localStorage.getItem('mta_jwt_token');
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
    return headers;
  }

  const apiKey = localStorage.getItem(API_KEY_STORAGE_KEY);
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

  return headers;
}

export function getAuthUploadHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};

  const token = localStorage.getItem('mta_jwt_token');
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
    return headers;
  }

  const apiKey = localStorage.getItem(API_KEY_STORAGE_KEY);
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

  return headers;
}
