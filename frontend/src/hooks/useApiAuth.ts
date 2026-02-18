/**
 * useApiAuth — provides authenticated API call helpers.
 *
 * Uses AuthContext for reactive auth state.
 * Uses apiAuth module for async header generation (works with Clerk or API keys).
 */
import { useCallback } from 'react';
import { useAuthContext } from '../contexts/AuthContext';
import { getAuthHeadersAsync, getAuthUploadHeadersAsync } from '../lib/apiAuth';

export function useApiAuth() {
  const { isAuthenticated, isClerkEnabled } = useAuthContext();

  const getHeaders = useCallback(async (): Promise<Record<string, string>> => {
    return getAuthHeadersAsync();
  }, []);

  const getUploadHeaders = useCallback(async (): Promise<Record<string, string>> => {
    return getAuthUploadHeadersAsync();
  }, []);

  return { getHeaders, getUploadHeaders, isAuthenticated, isClerkEnabled };
}
