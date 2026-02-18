/**
 * Auth store — bridges Clerk authentication with the API.
 *
 * With Clerk, auth state (user, session, tokens) is managed by @clerk/clerk-react.
 * This store provides helper functions to get auth headers for API calls,
 * maintaining backward compatibility with existing API key auth.
 *
 * Token refresh is handled natively by Clerk's getToken() — it automatically
 * refreshes expired tokens before returning them.
 */

const API_KEY_STORAGE_KEY = 'mta_api_key';

/**
 * Get auth headers for API calls.
 * Priority: 1) Clerk token (passed in), 2) API key from localStorage.
 *
 * Usage with Clerk:
 *   const { getToken } = useAuth();
 *   const token = await getToken();
 *   const headers = getAuthHeaders(token);
 */
export function getAuthHeaders(clerkToken?: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };

  if (clerkToken) {
    headers['Authorization'] = `Bearer ${clerkToken}`;
    return headers;
  }

  // Fallback to API key for backward compat
  const apiKey = localStorage.getItem(API_KEY_STORAGE_KEY);
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

  return headers;
}

/**
 * Get headers for file uploads (no Content-Type, let browser set multipart boundary).
 */
export function getAuthUploadHeaders(clerkToken?: string | null): Record<string, string> {
  const headers: Record<string, string> = {};

  if (clerkToken) {
    headers['Authorization'] = `Bearer ${clerkToken}`;
    return headers;
  }

  const apiKey = localStorage.getItem(API_KEY_STORAGE_KEY);
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

  return headers;
}

/**
 * Store/retrieve API key for backward compat (server-to-server use cases).
 */
export function getStoredAPIKey(): string | null {
  return localStorage.getItem(API_KEY_STORAGE_KEY);
}

export function setStoredAPIKey(key: string): void {
  localStorage.setItem(API_KEY_STORAGE_KEY, key);
}

export function clearStoredAPIKey(): void {
  localStorage.removeItem(API_KEY_STORAGE_KEY);
}
