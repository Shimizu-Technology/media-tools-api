/**
 * ClerkTokenSync — Syncs Clerk session tokens to localStorage.
 *
 * Clerk manages tokens internally, but our API client (lib/api.ts) reads
 * from localStorage. This bridge component keeps them in sync so existing
 * API calls work without modification.
 *
 * Clerk's getToken() handles refresh automatically — tokens are short-lived
 * (~60s) but getToken() returns a fresh one each time. We re-sync every 50s
 * to stay ahead of expiry.
 */
import { useEffect, useRef } from 'react';
import { useAuth } from '@clerk/clerk-react';

const TOKEN_KEY = 'mta_jwt_token';
const SYNC_INTERVAL_MS = 50_000; // Refresh every 50s (tokens expire ~60s)

export function ClerkTokenSync() {
  const { getToken, isSignedIn } = useAuth();
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    async function syncToken() {
      if (!isSignedIn) {
        localStorage.removeItem(TOKEN_KEY);
        return;
      }
      try {
        const token = await getToken();
        if (token) {
          localStorage.setItem(TOKEN_KEY, token);
        }
      } catch {
        // Token fetch failed — don't clear, might be transient
      }
    }

    // Initial sync
    syncToken();

    // Periodic refresh
    intervalRef.current = setInterval(syncToken, SYNC_INTERVAL_MS);

    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
      }
    };
  }, [getToken, isSignedIn]);

  // On sign-out, clear token
  useEffect(() => {
    if (!isSignedIn) {
      localStorage.removeItem(TOKEN_KEY);
    }
  }, [isSignedIn]);

  return null; // Invisible sync component
}
