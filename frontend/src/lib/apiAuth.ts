/**
 * API auth helpers — manages async token getter for authenticated API calls.
 *
 * Pattern from Brain Dump CLERK_AUTH_SETUP_GUIDE:
 * The auth provider sets a token getter function, and the API client
 * calls it before each request to get a fresh token.
 *
 * NOTE: The actual API client (lib/api.ts) uses synchronous getHeaders()
 * reading from localStorage. ClerkTokenSync bridges Clerk tokens into
 * localStorage to make this work. The async helpers below exist as the
 * "correct" pattern for future migration if api.ts is ever converted to
 * async, and are used by setAuthTokenGetter wiring in App.tsx.
 */

let authTokenGetter: (() => Promise<string | null>) | null = null;

/** Set the auth token getter (called from auth setup). */
export function setAuthTokenGetter(getter: () => Promise<string | null>) {
  authTokenGetter = getter;
}

/** Get auth headers for API calls. Async because Clerk tokens need fetching. */
export async function getAuthHeadersAsync(): Promise<Record<string, string>> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };

  // Try token getter first (Clerk)
  if (authTokenGetter) {
    const token = await authTokenGetter();
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
      return headers;
    }
  }

  // Fallback to stored JWT token
  const storedToken = localStorage.getItem('mta_jwt_token');
  if (storedToken) {
    headers['Authorization'] = `Bearer ${storedToken}`;
    return headers;
  }

  // Fallback to API key
  const apiKey = localStorage.getItem('mta_api_key');
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

  return headers;
}

/** Get upload headers (no Content-Type, let browser set multipart boundary). */
export async function getAuthUploadHeadersAsync(): Promise<Record<string, string>> {
  const headers: Record<string, string> = {};

  if (authTokenGetter) {
    const token = await authTokenGetter();
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
      return headers;
    }
  }

  const storedToken = localStorage.getItem('mta_jwt_token');
  if (storedToken) {
    headers['Authorization'] = `Bearer ${storedToken}`;
    return headers;
  }

  const apiKey = localStorage.getItem('mta_api_key');
  if (apiKey) {
    headers['X-API-Key'] = apiKey;
  }

  return headers;
}
