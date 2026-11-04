import { lazy, Suspense, useCallback, useEffect, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ChevronRight, KeyRound, LogOut } from 'lucide-react';
import { useAuthContext } from '../contexts/useAuthContext';
import { useTheme } from '../hooks/useTheme';
import { localApiKeyMode } from '../lib/webSession';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { getPasskeyStatus, passkeysSupported, PasskeyError, registerPasskey } from '../lib/passkeys';
import { getErrorMessage, getProcessingPreferences, updateProcessingPreferences } from '../lib/api';
import { RecoveryCodeSecuritySection } from '../components/RecoveryCodeSecuritySection';
import { getPasswordStatus } from '../lib/accountAuth';
import { useAuthCapabilities } from '../hooks/useAuthCapabilities';
import { EmailSection } from '../components/settings/EmailSection';
import { PasswordSection } from '../components/settings/PasswordSection';
import { UsageSection } from '../components/settings/UsageSection';
import { DevicesSection } from '../components/settings/DevicesSection';
import { SettingsCard } from '../components/settings/SettingsCard';
import { Button } from '../components/ui/Button';
import { Notice, Segmented, Switch } from '../components/ui/Field';
import { APP_ROUTES } from '../lib/appRoutes';

const DeleteAccountSection = lazy(() => import('../components/DeleteAccountSection').then((module) => ({ default: module.DeleteAccountSection })));

/** Grouped like a phone's Settings: a group heading, then plain sections. */
function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mt-10 first:mt-6" aria-label={title}>
      <h2 className="border-b border-separator pb-2 text-callout font-semibold text-text-secondary">{title}</h2>
      <div>{children}</div>
    </section>
  );
}

export function SettingsPage() {
  const { accountAuthEnabled, isAuthenticated, user, signOut } = useAuthContext();
  const signedIn = accountAuthEnabled && isAuthenticated;
  const { preference: themePreference, setPreference: setThemePreference } = useTheme();
  const { state: capabilities, checking: checkingCapabilities, refresh: refreshCapabilities } = useAuthCapabilities();
  const [passwordConfigured, setPasswordConfigured] = useState<boolean | null>(null);
  const [signingOut, setSigningOut] = useState(false);
  const [signOutError, setSignOutError] = useState('');
  const passwordsAvailable = capabilities.status === 'ready' && capabilities.passwordAuth;

  const loadPasswordStatus = useCallback(() => {
    getPasswordStatus().then((status) => setPasswordConfigured(status.configured)).catch(() => setPasswordConfigured(null));
  }, []);

  useEffect(() => {
    if (signedIn && passwordsAvailable) loadPasswordStatus();
  }, [loadPasswordStatus, passwordsAvailable, signedIn]);

  const handleSignOut = async () => {
    setSigningOut(true);
    setSignOutError('');
    try { await signOut(); } catch { setSignOutError('Could not sign out. Try again.'); } finally { setSigningOut(false); }
  };

  return (
    <div className="mx-auto max-w-2xl pb-12">
      <h1 className="pt-2 text-large-title">Settings</h1>

      {signedIn && (
        <Group title="Account">
          <SettingsCard
            title={user?.name || 'Your account'}
            description={user?.email}
            action={<Button onClick={() => void handleSignOut()} busy={signingOut} icon={<LogOut className="h-4 w-4" />}>Sign out</Button>}
          >
            {signOutError && <Notice tone="error">{signOutError}</Notice>}
          </SettingsCard>
          {passwordsAvailable && <EmailSection hasPassword={passwordConfigured} />}
          {passwordsAvailable && <PasswordSection configured={passwordConfigured} onChanged={loadPasswordStatus} />}
          {capabilities.status === 'unknown' && !checkingCapabilities && (
            <SettingsCard title="Email and password" description="Could not reach Media Tools to check these settings." action={<Button onClick={() => void refreshCapabilities()} busy={checkingCapabilities}>Try again</Button>} />
          )}
          <UsageSection />
        </Group>
      )}

      <Group title="Processing">
        {signedIn && <AutomaticSummariesSection />}
        <AIProcessingSection />
      </Group>

      <Group title="Agents and developers">
        <LinkRow to={APP_ROUTES.developer} title="Agent keys and activity" description="Give an agent or script its own key, choose what it may do, and see what it did." />
        <LinkRow to={APP_ROUTES.webhooks} title="Webhooks" description="Tell another service when a transcript or summary is ready." />
        <LinkRow to="/docs" title="API reference" description="Every endpoint, with examples." />
        {!accountAuthEnabled && <LinkRow to={APP_ROUTES.ops} title="System health" description="Queues, workers, and AI content reports." />}
      </Group>

      {signedIn && (
        <Group title="Security">
          <DevicesSection />
          <PasskeySecuritySection />
          <RecoveryCodeSecuritySection />
        </Group>
      )}

      <Group title="Appearance">
        <SettingsCard
          title="Light or dark"
          description="Follow this device, or always use one."
          action={<Segmented label="Appearance" value={themePreference} onChange={setThemePreference} options={[{ value: 'system', label: 'System' }, { value: 'light', label: 'Light' }, { value: 'dark', label: 'Dark' }]} />}
        />
      </Group>

      <Group title="Help and legal">
        <LinkRow to="/privacy" title="Privacy policy" />
        <LinkRow to="/terms" title="Terms of use" />
        <LinkRow to="/support" title="Support and safety" />
        <LinkRow to="/delete-account" title="Account deletion help" />
      </Group>

      {localApiKeyMode && <Group title="Development"><LocalKeySection /></Group>}

      {accountAuthEnabled && (
        <Group title="Danger zone">
          <Suspense fallback={null}>
            <DeleteAccountSection />
          </Suspense>
        </Group>
      )}
    </div>
  );
}

function LinkRow({ to, title, description }: { to: string; title: string; description?: string }) {
  return (
    <Link to={to} className="flex min-h-14 items-center gap-3 border-b border-separator py-3 last:border-b-0 hover:bg-fill">
      <span className="min-w-0 flex-1">
        <span className="block text-body font-medium">{title}</span>
        {description && <span className="mt-0.5 block text-callout text-text-secondary">{description}</span>}
      </span>
      <ChevronRight className="h-5 w-5 shrink-0 text-text-secondary" aria-hidden="true" />
    </Link>
  );
}

/** The server's per-account switch for titles and summaries written on their own. */
function AutomaticSummariesSection() {
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const { hasConsent } = useAIProcessingConsent();

  const load = useCallback(() => {
    getProcessingPreferences()
      .then((value) => { setEnabled(value.automatic_summaries); setError(''); })
      .catch((err: unknown) => setError(getErrorMessage(err)));
  }, []);
  useEffect(() => { load(); }, [load]);

  const change = async (next: boolean) => {
    const previous = enabled;
    setEnabled(next);
    setSaving(true);
    setError('');
    try {
      setEnabled((await updateProcessingPreferences({ automatic_summaries: next })).automatic_summaries);
    } catch (err) {
      setEnabled(previous);
      setError(getErrorMessage(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <section className="border-b border-separator py-5">
      <Switch
        label="Automatic summaries"
        checked={enabled ?? false}
        disabled={enabled === null || saving}
        onChange={(value) => void change(value)}
        description={enabled === null && !error
          ? 'Checking…'
          : <>When a transcript is ready, Media Tools gives it a title and writes a summary without being asked. A title you set yourself is never replaced.{!hasConsent && ' Nothing is sent until you allow AI processing below.'}</>}
      />
      {error && <div className="mt-3"><Notice tone="error" action={<Button variant="plain" onClick={load}>Retry</Button>}>{error}</Notice></div>}
    </section>
  );
}

function AIProcessingSection() {
  const { hasConsent, requestConsent, revokeConsent } = useAIProcessingConsent();
  return (
    <SettingsCard
      title="Third-party AI processing"
      description={<>
        {hasConsent ? 'Allowed for this account. Revoking stops future transcription, formatting, summary, and chat requests.' : 'Not allowed. Media Tools asks before sharing content with OpenAI, OpenRouter, or a selected model provider.'}{' '}
        <a href="/privacy#ai-processing" className="font-semibold text-accent underline">AI and privacy details</a>
      </>}
      action={hasConsent ? <Button variant="danger-plain" onClick={revokeConsent}>Revoke permission</Button> : <Button onClick={() => void requestConsent()}>Review and allow</Button>}
    />
  );
}

function PasskeySecuritySection() {
  const [count, setCount] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState('');
  const supported = passkeysSupported();

  const load = useCallback(async () => {
    try {
      setCount((await getPasskeyStatus()).count);
      setError('');
    } catch (caught) {
      setError(caught instanceof PasskeyError ? caught.message : 'Could not check your passkeys.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

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
    <SettingsCard
      title="Passkeys"
      description={<>
        <p>Use Face ID, Touch ID, or your device screen lock to sign in without a password.</p>
        <p className="mt-1 font-semibold text-text">{loading ? 'Checking passkeys…' : count === null ? 'Passkey status unavailable' : count === 0 ? 'No passkeys yet' : `${count} ${count === 1 ? 'passkey' : 'passkeys'} ready`}</p>
        {!supported && <p className="mt-1">Open this page in a current browser on a secure connection to add one.</p>}
        {error && <p className="mt-1 text-text" role="alert">{error}</p>}
      </>}
      action={(
        <div className="flex gap-2">
          {error && <Button onClick={() => { setLoading(true); void load(); }}>Retry</Button>}
          <Button onClick={() => void add()} disabled={!supported || loading} busy={adding} icon={<KeyRound className="h-4 w-4" />}>{adding ? 'Adding…' : count ? 'Add another' : 'Add a passkey'}</Button>
        </div>
      )}
    />
  );
}

function LocalKeySection() {
  const [cleared, setCleared] = useState(false);
  return (
    <SettingsCard
      title="Local API key"
      description="Clear the API key stored in this browser for local development mode."
      action={<Button onClick={() => { localStorage.removeItem('mta_api_key'); setCleared(true); window.setTimeout(() => setCleared(false), 2000); }}>{cleared ? 'Cleared' : 'Clear local key'}</Button>}
    />
  );
}
