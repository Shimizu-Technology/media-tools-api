import { useState, useSyncExternalStore } from 'react';
import { Loader2, WifiOff } from 'lucide-react';
import { useAuthContext } from '../contexts/useAuthContext';
import { isConnectionDegraded, subscribeWebSession } from '../lib/webSession';

/**
 * Shown while a signed-in session cannot reach the server (offline, 5xx, or a
 * throttled renewal). The session is intact; this only offers a retry.
 */
export function ConnectionBanner() {
  const degraded = useSyncExternalStore(subscribeWebSession, isConnectionDegraded);
  const { retrySession } = useAuthContext();
  const [busy, setBusy] = useState(false);
  if (!degraded) return null;

  const retry = async () => {
    setBusy(true);
    try { await retrySession(); } finally { setBusy(false); }
  };

  return (
    <div role="alert" className="flex flex-wrap items-center justify-between gap-3 border-b px-4 py-3 text-sm sm:px-6 lg:px-8" style={{ backgroundColor: 'var(--color-fill)', borderColor: 'var(--color-separator)', color: 'var(--color-text)' }}>
      <span className="flex items-center gap-2"><WifiOff className="h-4 w-4 shrink-0" />Can’t reach Media Tools right now. You are still signed in, and nothing was lost.</span>
      <button type="button" onClick={() => void retry()} disabled={busy} className="inline-flex min-h-11 items-center gap-2 rounded-md border px-4 font-semibold disabled:opacity-60" style={{ borderColor: 'var(--color-separator)' }}>
        {busy && <Loader2 className="h-4 w-4 animate-spin" />}{busy ? 'Trying…' : 'Try again'}
      </button>
    </div>
  );
}
