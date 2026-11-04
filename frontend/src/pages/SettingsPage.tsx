import { lazy, Suspense, useCallback, useEffect, useState } from 'react';
import { BrainCircuit, Check, ExternalLink, KeyRound, Loader2, Moon, Settings, Sun } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';
import { useTheme } from '../hooks/useTheme';
import { localApiKeyMode } from '../lib/webSession';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { getPasskeyStatus, passkeysSupported, PasskeyError, registerPasskey } from '../lib/passkeys';
import { RecoveryCodeSecuritySection } from '../components/RecoveryCodeSecuritySection';
import { getPasswordStatus } from '../lib/accountAuth';
import { useAuthCapabilities } from '../hooks/useAuthCapabilities';
import { EmailSection } from '../components/settings/EmailSection';
import { PasswordSection } from '../components/settings/PasswordSection';
import { UsageSection } from '../components/settings/UsageSection';
import { DevicesSection } from '../components/settings/DevicesSection';

const DeleteAccountSection = lazy(() => import('../components/DeleteAccountSection').then((module) => ({ default: module.DeleteAccountSection })));

export function SettingsPage() {
  const { accountAuthEnabled, isAuthenticated } = useAuthContext();
  const signedIn = accountAuthEnabled && isAuthenticated;
  const { isDark, toggle } = useTheme();
  const [cleared, setCleared] = useState(false);
  const { hasConsent: hasAIConsent, requestConsent: requestAIConsent, revokeConsent: revokeAIConsent } = useAIProcessingConsent();
  const { state: capabilities, checking: checkingCapabilities, refresh: refreshCapabilities } = useAuthCapabilities();
  const [passwordConfigured, setPasswordConfigured] = useState<boolean | null>(null);
  const passwordsAvailable = capabilities.status === 'ready' && capabilities.passwordAuth;

  const loadPasswordStatus = useCallback(() => {
    getPasswordStatus().then((status) => setPasswordConfigured(status.configured)).catch(() => setPasswordConfigured(null));
  }, []);

  useEffect(() => {
    if (signedIn && passwordsAvailable) loadPasswordStatus();
  }, [loadPasswordStatus, passwordsAvailable, signedIn]);

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
          {accountAuthEnabled ? 'Manage your sign-in, devices, usage, and workspace appearance.' : 'Manage appearance and local development credentials.'}
        </p>
      </section>

      {signedIn && passwordsAvailable && <EmailSection hasPassword={passwordConfigured} />}
      {signedIn && passwordsAvailable && <PasswordSection configured={passwordConfigured} onChanged={loadPasswordStatus} />}
      {signedIn && capabilities.status === 'unknown' && <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 className="text-xl font-semibold">Email and password</h2>
            <p className="mt-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Could not reach Media Tools to check these settings.</p>
          </div>
          <button type="button" onClick={() => void refreshCapabilities()} disabled={checkingCapabilities} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold disabled:opacity-50" style={{ borderColor: 'var(--color-border)' }}>
            {checkingCapabilities && <Loader2 className="h-4 w-4 animate-spin" />}{checkingCapabilities ? 'Checking…' : 'Try again'}
          </button>
        </div>
      </section>}
      {signedIn && <UsageSection />}
      {signedIn && <DevicesSection />}
      {signedIn && <PasskeySecuritySection />}
      {signedIn && <RecoveryCodeSecuritySection />}

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

      {localApiKeyMode && <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
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
