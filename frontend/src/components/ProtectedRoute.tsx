import { useState } from 'react';
import { SignInButton } from '@clerk/clerk-react';
import { Navigate, useLocation } from 'react-router-dom';
import { KeyRound, Loader2, Lock, LogIn } from 'lucide-react';
import { ApiKeySetup } from './ApiKeySetup';
import { useAuthContext } from '../contexts/useAuthContext';

interface ProtectedRouteProps {
  children: React.ReactNode;
  requireOwner?: boolean;
}

/**
 * ProtectedRoute gates the real application behind Clerk when configured.
 * In local/dev API-key mode, it falls back to the existing API key setup flow.
 */
export function ProtectedRoute({ children, requireOwner = false }: ProtectedRouteProps) {
  const location = useLocation();
  const { isClerkEnabled, isAuthenticated, isLoading, user } = useAuthContext();
  const [hasLocalApiKey, setHasLocalApiKey] = useState(() => !!localStorage.getItem('mta_api_key'));

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

  if (isClerkEnabled && !isAuthenticated) {
    return <SignInGate returnTo={`${location.pathname}${location.search}`} />;
  }

  if (!isClerkEnabled && !hasLocalApiKey) {
    return <ApiKeyGate onKeySet={() => setHasLocalApiKey(true)} />;
  }

  // Placeholder for future owner/admin roles. Until backend roles exist, keep ops
  // gated by API-key auth in the API client itself instead of pretending every
  // Clerk user is an owner.
  if (requireOwner && isClerkEnabled && user) {
    return <Navigate to="/app/developer" replace />;
  }

  return <>{children}</>;
}

function SignInGate({ returnTo }: { returnTo: string }) {
  return (
    <main className="min-h-screen px-4 py-10 flex items-center justify-center" style={{ backgroundColor: 'var(--color-surface)' }}>
      <section className="w-full max-w-lg rounded-[2rem] border p-8 text-center" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="mx-auto mb-5 flex h-14 w-14 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
          <Lock className="h-6 w-6" />
        </div>
        <p className="mb-2 text-xs font-semibold uppercase tracking-[0.24em]" style={{ color: 'var(--color-brand-500)' }}>Private workspace</p>
        <h1 className="text-3xl font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>Sign in to open Media Tools.</h1>
        <p className="mx-auto mt-3 max-w-sm text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
          Your transcripts, recordings, PDFs, summaries, chats, and collections stay tied to your account.
        </p>
        <SignInButton mode="modal" fallbackRedirectUrl={returnTo}>
          <button className="mt-6 inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-5 py-3 text-sm font-semibold text-white transition hover:opacity-90" style={{ backgroundColor: 'var(--color-brand-500)' }}>
            <LogIn className="h-4 w-4" />
            Sign in
          </button>
        </SignInButton>
      </section>
    </main>
  );
}

function ApiKeyGate({ onKeySet }: { onKeySet: () => void }) {
  return (
    <main className="min-h-screen px-4 py-10 flex items-center justify-center" style={{ backgroundColor: 'var(--color-surface)' }}>
      <section className="w-full max-w-xl rounded-[2rem] border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="mb-5 flex items-start gap-4">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
            <KeyRound className="h-5 w-5" />
          </div>
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-brand-500)' }}>Development mode</p>
            <h1 className="mt-1 text-2xl font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>Add an API key to continue.</h1>
            <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
              Clerk is not configured in this environment, so the app uses API-key auth for local development.
            </p>
          </div>
        </div>
        <ApiKeySetup onKeySet={onKeySet} hasKey={false} />
      </section>
    </main>
  );
}
