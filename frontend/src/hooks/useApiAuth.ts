/**
 * useApiAuth — provides authenticated API call helpers using Clerk tokens.
 *
 * Clerk's getToken() automatically handles token refresh, so we never need
 * to manually refresh. Tokens are short-lived (~60s) but getToken() caches
 * and refreshes them transparently.
 */
import { useAuth } from '@clerk/clerk-react';
import { useCallback } from 'react';
import { getAuthHeaders, getAuthUploadHeaders, getStoredAPIKey } from '../stores/authStore';

export function useApiAuth() {
  const { getToken, isSignedIn } = useAuth();

  const getHeaders = useCallback(async (): Promise<Record<string, string>> => {
    if (isSignedIn) {
      const token = await getToken();
      return getAuthHeaders(token);
    }
    // Fall back to API key
    return getAuthHeaders(null);
  }, [getToken, isSignedIn]);

  const getUploadHeaders = useCallback(async (): Promise<Record<string, string>> => {
    if (isSignedIn) {
      const token = await getToken();
      return getAuthUploadHeaders(token);
    }
    return getAuthUploadHeaders(null);
  }, [getToken, isSignedIn]);

  const isAuthenticated = isSignedIn || !!getStoredAPIKey();

  return { getHeaders, getUploadHeaders, isAuthenticated, isSignedIn };
}
