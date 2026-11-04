import { useEffect, useState, type ReactNode } from 'react';
import { Check, Copy, Download, KeyRound, Loader2, ShieldCheck } from 'lucide-react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';
import { passkeysSupported, PasskeyError, registerPasskey } from '../lib/passkeys';
import { beginRecoveryCodeRotation, confirmRecoveryCodeRotation, RecoveryCodeError, type RecoveryRotation } from '../lib/recoveryCodes';
import { commitWebOnboarding, completeWebOnboarding, getWebOnboardingStatus, OnboardingError, type WebOnboardingStatus } from '../lib/onboarding';
import { webSessionEnabled } from '../lib/webSession';
import { Mark } from '../components/ui/Mark';

export function JoinPage() {
  const navigate = useNavigate();
  const { isLoading: authLoading, refreshUser } = useAuthContext();
  const [status, setStatus] = useState<WebOnboardingStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [committing, setCommitting] = useState(false);
  const [addingPasskey, setAddingPasskey] = useState(false);
  const [rotation, setRotation] = useState<RecoveryRotation | null>(null);
  const [startingCodes, setStartingCodes] = useState(false);
  const [saved, setSaved] = useState(false);
  const [confirmingCodes, setConfirmingCodes] = useState(false);
  const [codesConfirmed, setCodesConfirmed] = useState(false);
  const [copied, setCopied] = useState(false);
  const [completed, setCompleted] = useState(false);
  const [error, setError] = useState('');

  const load = async () => {
    setLoading(true);
    setError('');
    try {
      const current = await getWebOnboardingStatus();
      setStatus(current);
      if (current.session_ready && !current.onboarding_required && !current.pending) {
        // Completion may have committed even when its response was lost. The
        // server-side requirement is the durable receipt on reload.
        setCompleted(true);
      } else if (current.complete && current.onboarding_required) {
        await completeWebOnboarding();
        setCompleted(true);
      } else if (current.pending && !current.session_ready) {
        setCommitting(true);
        const committed = await commitWebOnboarding();
        setStatus(committed);
        await refreshUser();
      }
    } catch (caught) {
      setError(messageFor(caught, 'Could not continue account setup.'));
    } finally {
      setCommitting(false);
      setLoading(false);
    }
  };

  useEffect(() => {
    if (authLoading || !webSessionEnabled) {
      if (!authLoading) setLoading(false);
      return;
    }
    void load();
    // The initial state machine intentionally runs once after auth restoration.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [authLoading]);

  const addPasskey = async () => {
    setAddingPasskey(true);
    setError('');
    try {
      await registerPasskey();
      const current = await getWebOnboardingStatus();
      setStatus(current);
    } catch (caught) {
      setError(messageFor(caught, 'Could not create a passkey.'));
    } finally {
      setAddingPasskey(false);
    }
  };

  const startRecoveryCodes = async () => {
    setStartingCodes(true);
    setError('');
    try {
      setRotation(await beginRecoveryCodeRotation());
      setCodesConfirmed(false);
      setSaved(false);
      setCopied(false);
    } catch (caught) {
      setError(messageFor(caught, 'Could not create recovery codes.'));
    } finally {
      setStartingCodes(false);
    }
  };

  const activateRecoveryCodes = async () => {
    if (!rotation || !saved) return;
    setConfirmingCodes(true);
    setError('');
    try {
      if (!codesConfirmed) {
        await confirmRecoveryCodeRotation(rotation.rotation_id);
        setCodesConfirmed(true);
      }
      const current = await getWebOnboardingStatus();
      if (!current.complete) throw new OnboardingError('Account recovery is not complete yet.', 'onboarding_incomplete');
      await completeWebOnboarding();
      setRotation(null);
      setCodesConfirmed(false);
      setStatus(current);
      setCompleted(true);
    } catch (caught) {
      setError(messageFor(caught, 'Could not activate recovery codes.'));
    } finally {
      setConfirmingCodes(false);
    }
  };

  const copyCodes = async () => {
    if (!rotation) return;
    try {
      await navigator.clipboard.writeText(rotation.codes.join('\n'));
      setCopied(true);
      window.setTimeout(() => setCopied(false), 3000);
    } catch {
      setError('Could not copy the codes. Select and save them manually.');
    }
  };

  const downloadCodes = () => {
    if (!rotation) return;
    const blob = new Blob([`Media Tools recovery codes\n\n${rotation.codes.join('\n')}\n\nEach code works once. Store this file somewhere private.\n`], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'media-tools-recovery-codes.txt';
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 0);
  };

  const passkeyReady = Boolean(status?.passkeys && status.passkeys > 0);
  const unavailable = !webSessionEnabled;
  const missing = Boolean(!loading && !error && !completed && status && !status.pending && !status.onboarding_required);

  return (
    <main className="min-h-screen px-4 py-6 sm:py-10" style={{ backgroundColor: 'var(--color-background)' }}>
      <div className="mx-auto max-w-3xl">
        <header className="flex items-center justify-between gap-4">
          <Link to="/" className="flex min-h-11 items-center gap-3 rounded-md pr-3 focus:outline-none focus:ring-2 focus:ring-[var(--color-accent-text)]">
            <Mark size={40} />
            <span><span className="block text-sm font-semibold">Media Tools</span><span className="block text-xs" style={{ color: 'var(--color-text-secondary)' }}>Secure account setup</span></span>
          </Link>
          <Link to="/support" className="inline-flex min-h-11 items-center px-3 text-sm font-semibold" style={{ color: 'var(--color-accent-text)' }}>Get help</Link>
        </header>

        <section className="mt-6 overflow-hidden rounded-xl border shadow-overlay sm:mt-10" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-separator)' }}>
          <div className="border-b px-6 py-7 sm:px-10 sm:py-9" style={{ borderColor: 'var(--color-separator)' }}>
            <h1 className="max-w-2xl text-title sm:text-[2.25rem] sm:leading-[2.75rem]">Set up the ways you will sign in and recover your account.</h1>
            <p className="mt-3 max-w-2xl text-sm leading-6 sm:text-base" style={{ color: 'var(--color-text-secondary)' }}>Your passkey handles everyday sign-in. Recovery codes keep you from getting locked out if that device is unavailable.</p>
          </div>

          <div className="px-6 py-7 sm:px-10 sm:py-9">
            <ol className="grid gap-3 sm:grid-cols-3" aria-label="Account setup progress">
              <ProgressStep number="1" label="Secure link" done={Boolean(status?.session_ready || completed)} active={!status?.session_ready && !completed} />
              <ProgressStep number="2" label="Add passkey" done={passkeyReady || completed} active={Boolean(status?.session_ready && !passkeyReady && !completed)} />
              <ProgressStep number="3" label="Save recovery codes" done={completed} active={passkeyReady && !completed} />
            </ol>

            {(loading || authLoading || committing) && <StatusPanel icon={<Loader2 className="h-6 w-6 animate-spin" />} title={committing ? 'Creating your secure browser session…' : 'Checking your setup…'} body="Keep this page open. Your sign-in credentials stay protected in secure cookies." />}

            {!loading && unavailable && <StatusPanel title="Account setup is not available yet." body="This deployment has not enabled first-party browser accounts. Keep the original link and try again after setup is enabled." />}

            {!loading && status?.session_ready && !passkeyReady && !completed && (
              <StatusPanel icon={<KeyRound className="h-6 w-6" />} title="Create your passkey" body="Use Face ID, Touch ID, or your device lock. Media Tools never receives your biometric data.">
                {passkeysSupported() ? <button type="button" onClick={() => void addPasskey()} disabled={addingPasskey} className="mt-5 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-md px-5 text-sm font-semibold text-on-accent disabled:opacity-60 sm:w-auto" style={{ backgroundColor: 'var(--color-accent-fill)' }}>{addingPasskey && <Loader2 className="h-4 w-4 animate-spin" />}{addingPasskey ? 'Creating passkey…' : 'Create passkey'}</button> : <p className="mt-4 rounded-md border p-4 text-sm" role="alert" style={{ borderColor: 'var(--color-separator)', color: 'var(--color-text-secondary)' }}>Open this page in a current version of Safari, Chrome, or Edge on a device that supports passkeys.</p>}
              </StatusPanel>
            )}

            {!loading && passkeyReady && !completed && !rotation && (
              <StatusPanel icon={<ShieldCheck className="h-6 w-6" />} title="Save your recovery codes" body="These one-time codes are the backup for your passkey. We will activate them only after you confirm that you saved the full set.">
                <button type="button" onClick={() => void startRecoveryCodes()} disabled={startingCodes} className="mt-5 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-md px-5 text-sm font-semibold text-on-accent disabled:opacity-60 sm:w-auto" style={{ backgroundColor: 'var(--color-accent-fill)' }}>{startingCodes && <Loader2 className="h-4 w-4 animate-spin" />}{startingCodes ? 'Creating codes…' : 'Create recovery codes'}</button>
              </StatusPanel>
            )}

            {rotation && !completed && (
              <div className="mt-7 rounded-lg border p-5 sm:p-6" style={{ borderColor: 'var(--color-separator)', backgroundColor: 'var(--color-fill)' }}>
                <h2 className="text-xl font-semibold">Save all {rotation.codes.length} recovery codes</h2>
                <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>They are shown once in this setup. Each code can sign you in one time.</p>
                <ol className="mt-5 grid gap-2 rounded-lg border p-3 sm:grid-cols-2 sm:p-4" style={{ borderColor: 'var(--color-separator)', backgroundColor: 'var(--color-surface)' }}>
                  {rotation.codes.map((code, index) => <li key={code} className="flex min-h-10 items-center gap-3 rounded-sm px-2 font-mono text-xs sm:text-sm"><span className="w-5 text-right" style={{ color: 'var(--color-text-secondary)' }}>{index + 1}</span><span className="break-all select-all">{code}</span></li>)}
                </ol>
                <div className="mt-4 grid gap-3 sm:grid-cols-2">
                  <button type="button" onClick={() => void copyCodes()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-md border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-separator)' }}>{copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}{copied ? 'Copied' : 'Copy all codes'}</button>
                  <button type="button" onClick={downloadCodes} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-md border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-separator)' }}><Download className="h-4 w-4" />Download text file</button>
                </div>
                <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-lg border p-4" style={{ borderColor: saved ? 'var(--color-accent-text)' : 'var(--color-separator)', backgroundColor: 'var(--color-surface)' }}>
                  <input type="checkbox" checked={saved} onChange={(event) => setSaved(event.target.checked)} className="mt-1 h-5 w-5 accent-[var(--color-accent-text)]" />
                  <span><span className="block text-sm font-semibold">I saved every code somewhere private</span><span className="mt-1 block text-xs leading-5" style={{ color: 'var(--color-text-secondary)' }}>Confirmation activates this set and completes account recovery setup.</span></span>
                </label>
                <button type="button" onClick={() => void activateRecoveryCodes()} disabled={!saved || confirmingCodes} className="mt-5 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-md px-5 text-sm font-semibold text-on-accent disabled:opacity-50" style={{ backgroundColor: 'var(--color-accent-fill)' }}>{confirmingCodes && <Loader2 className="h-4 w-4 animate-spin" />}{confirmingCodes ? 'Finishing…' : codesConfirmed ? 'Finish account setup' : 'Activate codes and finish'}</button>
              </div>
            )}

            {completed && <StatusPanel icon={<Check className="h-6 w-6" />} title="Your account is ready" body="Your passkey and recovery codes are active. You can now use Media Tools on this browser."><button type="button" onClick={() => navigate('/app')} className="mt-5 min-h-12 w-full rounded-md px-5 text-sm font-semibold text-on-accent sm:w-auto" style={{ backgroundColor: 'var(--color-accent-fill)' }}>Open Media Tools</button></StatusPanel>}

            {missing && <StatusPanel title="This setup link is no longer available." body="The link may have expired, already been used, or not transferred successfully. Ask the person who invited you for a new link." />}

            {error && <div className="mt-6 rounded-lg border p-4" role="alert" style={{ borderColor: 'var(--color-danger)', color: 'var(--color-danger)' }}><p className="text-sm font-semibold">{error}</p><button type="button" onClick={() => void load()} className="mt-3 min-h-11 rounded-md border px-4 text-sm font-semibold" style={{ borderColor: 'currentColor' }}>Try again</button></div>}
          </div>
        </section>
      </div>
    </main>
  );
}

function ProgressStep({ number, label, done, active }: { number: string; label: string; done: boolean; active: boolean }) {
  return <li className="flex items-center gap-3 rounded-md border px-3 py-3" aria-current={active ? 'step' : undefined} style={{ borderColor: active ? 'var(--color-accent-text)' : 'var(--color-separator)', backgroundColor: done ? 'var(--color-accent-tint)' : 'transparent' }}><span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-xs font-bold" style={{ backgroundColor: done || active ? 'var(--color-accent-text)' : 'var(--color-fill)', color: done || active ? 'var(--color-on-accent)' : 'var(--color-text-secondary)' }}>{done ? <Check className="h-4 w-4" /> : number}</span><span className="text-sm font-semibold">{label}</span></li>;
}

function StatusPanel({ icon, title, body, children }: { icon?: ReactNode; title: string; body: string; children?: ReactNode }) {
  return <div className="mt-7 rounded-lg border p-5 sm:p-6" style={{ borderColor: 'var(--color-separator)', backgroundColor: 'var(--color-fill)' }}>{icon && <div className="flex h-12 w-12 items-center justify-center rounded-lg" style={{ backgroundColor: 'var(--color-accent-tint)', color: 'var(--color-accent-text)' }}>{icon}</div>}<h2 className={`${icon ? 'mt-4' : ''} text-xl font-semibold`}>{title}</h2><p className="mt-2 max-w-xl text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{body}</p>{children}</div>;
}

function messageFor(caught: unknown, fallback: string): string {
  if (caught instanceof OnboardingError || caught instanceof PasskeyError || caught instanceof RecoveryCodeError) return caught.message;
  return fallback;
}
