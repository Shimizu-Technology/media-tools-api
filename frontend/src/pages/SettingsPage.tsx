import { lazy, Suspense, useEffect, useState } from 'react';
import { BrainCircuit, Check, ExternalLink, KeyRound, Loader2, Moon, Settings, Sun, UserRound } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';
import { useTheme } from '../hooks/useTheme';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { isWebSessionActive } from '../lib/webSession';
import { getPasskeyStatus, passkeysSupported, PasskeyError, registerPasskey } from '../lib/passkeys';
import { RecoveryCodeSecuritySection } from '../components/RecoveryCodeSecuritySection';

const DeleteAccountSection = lazy(() => import('../components/DeleteAccountSection').then((module) => ({ default: module.DeleteAccountSection })));

export function SettingsPage() {
  const { user, accountAuthEnabled, isFirstPartySession } = useAuthContext();
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
          {accountAuthEnabled ? 'Manage your sign-in security, account, and workspace appearance.' : 'Manage account context, appearance, and local development credentials.'}
        </p>
      </section>

      {isFirstPartySession && <PasskeySecuritySection />}
      {isFirstPartySession && <RecoveryCodeSecuritySection />}

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
              {accountAuthEnabled ? (isWebSessionActive() ? 'Signed in with a durable Media Tools browser session.' : 'Signed in through the previous account provider.') : 'Running in local API-key mode.'}
            </p>
            <div className="mt-4 rounded-2xl border p-4" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
              <p className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>{user?.name || 'Workspace user'}</p>
              <p className="mt-1 break-all text-sm" style={{ color: 'var(--color-text-secondary)' }}>{user?.email || 'No account loaded in this environment'}</p>
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

      {!accountAuthEnabled && <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
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

      {accountAuthEnabled && (
        <Suspense fallback={null}>
          <DeleteAccountSection />
        </Suspense>
      )}
    </div>
  );
}

function PasskeySecuritySection() {
  const [count, setCount] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState('');
  const supported = passkeysSupported();

  const load = async () => {
    setLoading(true);
    setError('');
    try {
      setCount((await getPasskeyStatus()).count);
    } catch (caught) {
      setError(caught instanceof PasskeyError ? caught.message : 'Could not check your passkeys.');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { void load(); }, []);

  const add = async () => {
    setAdding(true);
    setError('');
    try {
      setCount(await registerPasskey());
    } catch (caught) {
      if (caught instanceof DOMException && caught.name === 'NotAllowedError') setError('Passkey setup was canceled.');
      else setError(caught instanceof PasskeyError ? caught.message : 'Could not add this passkey.');
    } finally {
      setAdding(false);
    }
  };

  return (
    <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex items-start gap-4">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}><KeyRound className="h-5 w-5" /></div>
          <div>
            <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>Passkeys</h2>
            <p className="mt-2 max-w-xl text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
              Use Face ID, Touch ID, or your device screen lock to sign in without a password.
            </p>
            <p className="mt-2 text-sm font-semibold" style={{ color: count && count > 0 ? 'var(--color-success)' : 'var(--color-text-secondary)' }}>
              {loading ? 'Checking passkeys…' : count === null ? 'Passkey status unavailable' : `${count} ${count === 1 ? 'passkey' : 'passkeys'} ready`}
            </p>
            {!supported && <p className="mt-2 text-xs" style={{ color: 'var(--color-text-muted)' }}>Open this page in a current browser on a secure connection to add one.</p>}
            {error && <p className="mt-2 text-sm" role="alert" style={{ color: 'var(--color-danger)' }}>{error}</p>}
          </div>
        </div>
        <div className="flex shrink-0 gap-2">
          {error && <button type="button" onClick={() => void load()} className="min-h-11 rounded-xl border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-border)' }}>Retry</button>}
          <button type="button" onClick={() => void add()} disabled={!supported || loading || adding} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-60" style={{ backgroundColor: 'var(--color-brand-500)' }}>
            {adding ? <Loader2 className="h-4 w-4 animate-spin" /> : <KeyRound className="h-4 w-4" />}
            {adding ? 'Adding…' : count ? 'Add another passkey' : 'Add a passkey'}
          </button>
        </div>
      </div>
    </section>
  );
}
