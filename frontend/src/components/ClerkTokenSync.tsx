/**
 * ClerkTokenSync — bridges Clerk session tokens into localStorage
 * so the existing synchronous api.ts getHeaders() can read them.
 *
 * Renders nothing. Must be inside <ClerkProvider> and <SignedIn>.
 */
import { useEffect } from 'react';
import { useAuth } from '@clerk/clerk-react';

const TOKEN_KEY = 'mta_jwt_token';

export function ClerkTokenSync() {
  const { getToken, isSignedIn } = useAuth();

  useEffect(() => {
    if (!isSignedIn) {
      localStorage.removeItem(TOKEN_KEY);
      return;
    }

    let cancelled = false;

    // Sync token immediately on sign-in
    const syncToken = async () => {
      try {
        const token = await getToken();
        if (!cancelled && token) {
          localStorage.setItem(TOKEN_KEY, token);
        }
      } catch (err) {
        console.warn('ClerkTokenSync: failed to get token', err);
      }
    };

    syncToken();

    // Refresh token every 50 seconds (Clerk tokens expire in ~60s)
    const interval = setInterval(syncToken, 50_000);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [getToken, isSignedIn]);

  // Clean up on sign-out
  useEffect(() => {
    if (!isSignedIn) {
      localStorage.removeItem(TOKEN_KEY);
    }
  }, [isSignedIn]);

  return null;
}
