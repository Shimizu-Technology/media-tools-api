/**
 * ClerkTokenSync — bridges Clerk session tokens into localStorage
 * so the existing synchronous api.ts getHeaders() can read them.
 *
 * Blocks child rendering until the first token sync completes,
 * preventing unauthenticated API calls on page load.
 *
 * Must be inside <ClerkProvider>.
 */
import { useEffect, useState } from 'react';
import { useAuth } from '@clerk/clerk-react';
import type { ReactNode } from 'react';

const TOKEN_KEY = 'mta_jwt_token';

export function ClerkTokenSync({ children }: { children: ReactNode }) {
  const { getToken, isSignedIn } = useAuth();
  const [ready, setReady] = useState(false);

  useEffect(() => {
    if (!isSignedIn) {
      localStorage.removeItem(TOKEN_KEY);
      return;
    }

    let cancelled = false;

    const syncToken = async () => {
      try {
        const token = await getToken();
        if (!cancelled && token) {
          localStorage.setItem(TOKEN_KEY, token);
        }
      } catch (err) {
        console.warn('ClerkTokenSync: failed to get token', err);
      }
      if (!cancelled) setReady(true);
    };

    syncToken();

    // Refresh token every 50 seconds (Clerk tokens expire in ~60s)
    const interval = setInterval(syncToken, 50_000);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [getToken, isSignedIn]);

  // Block rendering until first token sync completes
  if (isSignedIn && !ready) return null;

  return <>{children}</>;
}
