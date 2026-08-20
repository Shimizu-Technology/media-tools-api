/**
 * API auth helpers — manages async token getter for authenticated API calls.
 *
 * Pattern from Brain Dump CLERK_AUTH_SETUP_GUIDE:
 * The auth provider sets a token getter function, and the API client
 * calls it before each request to get a fresh token.
 *
 * The API client calls these helpers before each request so Clerk tokens are
 * fetched just-in-time and do not need to be mirrored into localStorage.
 */

type AuthTokenGetter = (forceRefresh: boolean) => Promise<string | null>;

let authTokenGetter: AuthTokenGetter | null = null;

/** Set the auth token getter (called from auth setup). */
export function setAuthTokenGetter(getter: AuthTokenGetter) {
  authTokenGetter = getter;
}

async function getClerkToken(forceRefresh = false): Promise<string | null> {
  if (!authTokenGetter) return null;
  return authTokenGetter(forceRefresh);
}

/** Get auth headers for API calls. Async because Clerk tokens need fetching. */
export async function getAuthHeadersAsync(): Promise<Record<string, string>> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };

  // Try token getter first (Clerk)
  if (authTokenGetter) {
    const token = await getClerkToken();
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
    const token = await getClerkToken();
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

/**
 * Force Clerk to mint a fresh token after the API rejects a cached one.
 *
 * Returning null distinguishes Clerk mode from API-key/legacy-token mode so
 * callers only replay requests that can actually recover with a fresh token.
 */
export async function getRefreshedClerkHeaders(
  includeContentType: boolean,
): Promise<Record<string, string> | null> {
  if (!authTokenGetter) return null;
  const token = await getClerkToken(true);
  if (!token) return null;

  return {
    ...(includeContentType ? { 'Content-Type': 'application/json' } : {}),
    Authorization: `Bearer ${token}`,
  };
}
