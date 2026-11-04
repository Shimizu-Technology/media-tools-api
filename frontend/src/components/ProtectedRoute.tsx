import { lazy, Suspense, useState } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { Loader2, RefreshCw } from 'lucide-react';
import { useAuthContext } from '../contexts/useAuthContext';
import { isWebOnboardingRequired, localApiKeyMode } from '../lib/webSession';

// Resolved at build time: null in production, so the development-only gate
// never ships to users.
const LocalApiKeyGate = localApiKeyMode ? lazy(() => import('./LocalApiKeyGate')) : null;

interface ProtectedRouteProps {
  children: React.ReactNode;
  requireOwner?: boolean;
}

/**
 * ProtectedRoute gates the application behind a Media Tools account session.
 * A session that could not be checked (offline, server trouble) is shown as a
 * retry, never as a sign-in prompt: the account is not signed out.
 */
export function ProtectedRoute({ children, requireOwner = false }: ProtectedRouteProps) {
  const location = useLocation();
  const { accountAuthEnabled, isAuthenticated, isLoading, isUnavailable, retrySession } = useAuthContext();
  const [hasLocalApiKey, setHasLocalApiKey] = useState(() => localApiKeyMode && !!localStorage.getItem('mta_api_key'));

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center" style={{ backgroundColor: 'var(--color-surface)' }}>
        <div className="flex items-center gap-3 rounded-2xl border px-5 py-4" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}>
          <Loader2 className="w-5 h-5 animate-spin" />
          <span className="text-sm font-medium">Checking your workspace...</span>
        </div>
      </div>
    );
  }

  if (isUnavailable) return <SessionUnavailable onRetry={() => void retrySession()} />;

  if (accountAuthEnabled && !isAuthenticated) {
    const next = `${location.pathname}${location.search}`;
    return <Navigate to={`/sign-in?next=${encodeURIComponent(next)}`} replace />;
  }

  if (!accountAuthEnabled && !hasLocalApiKey) {
    return LocalApiKeyGate
      ? <Suspense fallback={null}><LocalApiKeyGate onKeySet={() => setHasLocalApiKey(true)} /></Suspense>
      : <Navigate to="/sign-in" replace />;
  }

  if (accountAuthEnabled && isAuthenticated && isWebOnboardingRequired()) {
    return <Navigate to="/join" replace />;
  }

  // Placeholder for future owner/admin roles. Until backend roles exist, keep
  // ops gated by API-key auth in the API client itself instead of pretending
  // every account is an owner.
  if (requireOwner && accountAuthEnabled) {
    return <Navigate to="/app/developer" replace />;
  }

  return <>{children}</>;
}

function SessionUnavailable({ onRetry }: { onRetry: () => void }) {
  const [busy, setBusy] = useState(false);
  const retry = () => {
    setBusy(true);
    onRetry();
    window.setTimeout(() => setBusy(false), 1200);
  };
  return (
    <main className="min-h-screen px-4 py-10 flex items-center justify-center" style={{ backgroundColor: 'var(--color-surface)' }}>
      <section className="w-full max-w-md rounded-[2rem] border p-6 text-center sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }} role="alert">
        <h1 className="text-2xl font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>Can’t reach Media Tools</h1>
        <p className="mt-3 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
          We could not check your session right now. Nothing has been signed out or changed. We keep trying, or you can try now.
        </p>
        <button type="button" onClick={retry} disabled={busy} className="mt-6 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold disabled:opacity-60" style={{ backgroundColor: 'var(--color-brand-500)', color: 'var(--color-on-brand)' }}>
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}{busy ? 'Trying…' : 'Try again'}
        </button>
      </section>
    </main>
  );
}
