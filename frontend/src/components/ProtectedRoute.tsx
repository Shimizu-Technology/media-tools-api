import { useState } from 'react';
import { SignInButton } from '@clerk/clerk-react';
import { Navigate, useLocation } from 'react-router-dom';
import { KeyRound, Loader2, Lock, LogIn } from 'lucide-react';
import { ApiKeySetup } from './ApiKeySetup';
import { PasskeySignInButton } from './PasskeySignInButton';
import { RecoveryCodeSignIn } from './RecoveryCodeSignIn';
import { useAuthContext } from '../contexts/useAuthContext';
import { webSessionEnabled } from '../lib/webSession';

interface ProtectedRouteProps {
  children: React.ReactNode;
  requireOwner?: boolean;
}

/**
 * ProtectedRoute gates the real application behind account auth when configured.
 * In local/dev API-key mode, it falls back to the existing API key setup flow.
 */
export function ProtectedRoute({ children, requireOwner = false }: ProtectedRouteProps) {
  const location = useLocation();
  const { isClerkEnabled, accountAuthEnabled, isAuthenticated, isLoading } = useAuthContext();
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

  if (accountAuthEnabled && !isAuthenticated) {
    return <SignInGate returnTo={`${location.pathname}${location.search}`} isClerkEnabled={isClerkEnabled} />;
  }

  if (!accountAuthEnabled && !hasLocalApiKey) {
    return <ApiKeyGate onKeySet={() => setHasLocalApiKey(true)} />;
  }

  // Placeholder for future owner/admin roles. Until backend roles exist, keep ops
  // gated by API-key auth in the API client itself instead of pretending every
  // Clerk user is an owner.
  if (requireOwner && accountAuthEnabled) {
    return <Navigate to="/app/developer" replace />;
  }

  return <>{children}</>;
}

function SignInGate({ returnTo, isClerkEnabled }: { returnTo: string; isClerkEnabled: boolean }) {
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
        {webSessionEnabled && <div className="mt-6 space-y-3"><PasskeySignInButton className="w-full" /><RecoveryCodeSignIn className="w-full" /></div>}
        {isClerkEnabled && (
          <div className={webSessionEnabled ? 'mt-4 border-t pt-4' : 'mt-6'} style={{ borderColor: 'var(--color-border)' }}>
            {webSessionEnabled && <p className="mb-3 text-xs" style={{ color: 'var(--color-text-muted)' }}>Migrating from the previous sign-in?</p>}
            <SignInButton mode="modal" fallbackRedirectUrl={returnTo}>
              <button className="inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-xl border px-5 py-3 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
                <LogIn className="h-4 w-4" />
                {webSessionEnabled ? 'Use previous sign-in' : 'Sign in'}
              </button>
            </SignInButton>
          </div>
        )}
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
