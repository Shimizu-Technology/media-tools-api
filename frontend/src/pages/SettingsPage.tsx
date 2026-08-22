import { lazy, Suspense, useState } from 'react';
import { BrainCircuit, Check, ExternalLink, KeyRound, Moon, Settings, Sun, UserRound } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';
import { useTheme } from '../hooks/useTheme';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';

const DeleteAccountSection = lazy(() => import('../components/DeleteAccountSection').then((module) => ({ default: module.DeleteAccountSection })));

export function SettingsPage() {
  const { user, isClerkEnabled } = useAuthContext();
  const { isDark, toggle } = useTheme();
  const [cleared, setCleared] = useState(false);
  const { hasConsent: hasAIConsent, requestConsent: requestAIConsent, revokeConsent: revokeAIConsent } = useAIProcessingConsent();

  const clearLocalKey = () => {
    localStorage.removeItem('mta_api_key');
    setCleared(true);
    setTimeout(() => setCleared(false), 2000);
  };

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <section className="rounded-[2rem] border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.2em]" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
          <Settings className="h-3.5 w-3.5" />
          Settings
        </div>
        <h1 className="mt-5 text-3xl font-semibold tracking-tight sm:text-4xl" style={{ color: 'var(--color-text-primary)' }}>Workspace preferences</h1>
        <p className="mt-3 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
          {isClerkEnabled ? 'Manage your account context and workspace appearance.' : 'Manage account context, appearance, and local development credentials.'}
        </p>
      </section>

      <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-4">
            <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
              <BrainCircuit className="h-5 w-5" />
            </div>
            <div>
              <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>Third-party AI processing</h2>
              <p className="mt-2 max-w-xl text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
                {hasAIConsent ? 'Allowed for this account. You can revoke permission for future transcription, formatting, summary, and chat requests.' : 'Not allowed. Media Tools will ask before sharing content with OpenAI, OpenRouter, or a selected model provider.'}
              </p>
              <a href="/privacy#ai-processing" className="mt-2 inline-flex min-h-11 items-center text-sm font-semibold underline" style={{ color: 'var(--color-brand-500)' }}>Review AI and privacy details</a>
            </div>
          </div>
          <button
            type="button"
            onClick={() => hasAIConsent ? revokeAIConsent() : void requestAIConsent()}
            className="inline-flex min-h-11 shrink-0 items-center justify-center rounded-xl border px-4 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)]"
            style={{ borderColor: 'var(--color-border)', color: hasAIConsent ? 'var(--color-danger)' : 'var(--color-text-primary)' }}
          >
            {hasAIConsent ? 'Revoke permission' : 'Review and allow'}
          </button>
        </div>
      </section>

      <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>Help and legal</h2>
        <p className="mt-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Public resources are available without signing in.</p>
        <div className="mt-4 grid gap-2 sm:grid-cols-2">
          {[
            ['/privacy', 'Privacy policy'],
            ['/terms', 'Terms of use'],
            ['/support', 'Support and safety'],
            ['/delete-account', 'Account deletion help'],
          ].map(([href, label]) => (
            <Link key={href} to={href} className="inline-flex min-h-11 items-center justify-between rounded-xl border px-4 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
              {label}<ExternalLink className="h-4 w-4" style={{ color: 'var(--color-text-muted)' }} />
            </Link>
          ))}
        </div>
      </section>

      <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex min-w-0 items-start gap-4">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
            <UserRound className="h-5 w-5" />
          </div>
          <div className="min-w-0 flex-1">
            <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>Account</h2>
            <p className="mt-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>
              {isClerkEnabled ? 'Signed in through Clerk.' : 'Running in local API-key mode.'}
            </p>
            <div className="mt-4 rounded-2xl border p-4" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
              <p className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>{user?.name || 'Workspace user'}</p>
              <p className="mt-1 break-all text-sm" style={{ color: 'var(--color-text-secondary)' }}>{user?.email || 'No Clerk account loaded in this environment'}</p>
            </div>
          </div>
        </div>
      </section>

      <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-4">
            <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-surface-subtle)', color: 'var(--color-brand-500)' }}>
              {isDark ? <Moon className="h-5 w-5" /> : <Sun className="h-5 w-5" />}
            </div>
            <div>
              <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>Appearance</h2>
              <p className="mt-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Switch between light and dark mode.</p>
            </div>
          </div>
          <button type="button" onClick={toggle} className="inline-flex min-h-11 items-center justify-center rounded-xl border px-4 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
            Use {isDark ? 'light' : 'dark'} mode
          </button>
        </div>
      </section>

      {!isClerkEnabled && <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-4">
            <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-surface-subtle)', color: 'var(--color-brand-500)' }}>
              <KeyRound className="h-5 w-5" />
            </div>
            <div>
              <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>Local API key</h2>
              <p className="mt-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Clear the API key stored in this browser for local development mode.</p>
            </div>
          </div>
          <button type="button" onClick={clearLocalKey} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)]" style={{ borderColor: 'var(--color-border)', color: cleared ? 'var(--color-success)' : 'var(--color-text-primary)' }}>
            {cleared && <Check className="h-4 w-4" />}
            {cleared ? 'Cleared' : 'Clear local key'}
          </button>
        </div>
      </section>}

      {isClerkEnabled && (
        <Suspense fallback={null}>
          <DeleteAccountSection />
        </Suspense>
      )}
    </div>
  );
}
