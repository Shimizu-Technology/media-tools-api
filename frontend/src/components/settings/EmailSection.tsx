import { useState, type FormEvent } from 'react';
import { BadgeCheck, Mail } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { useAuthContext } from '../../contexts/useAuthContext';
import { AccountAuthError, confirmEmailVerification, finishEmailChange, startEmailChange, startEmailVerification } from '../../lib/accountAuth';
import { setSignInHint, setWebSessionActive } from '../../lib/webSession';
import { Notice } from '../auth/AuthShell';
import { CodeField, EmailField, PasswordField, PrimaryButton, SecondaryButton } from '../auth/fields';
import { SettingsCard } from './SettingsCard';

type Mode = 'idle' | 'verify' | 'change-request' | 'change-confirm';

export function EmailSection({ hasPassword }: { hasPassword: boolean | null }) {
  const navigate = useNavigate();
  const { user, refreshUser } = useAuthContext();
  const verified = user?.email_verified === true;
  const [mode, setMode] = useState<Mode>('idle');
  const [newEmail, setNewEmail] = useState('');
  const [currentPassword, setCurrentPassword] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');

  const fail = (caught: unknown, fallback: string) => setError(caught instanceof AccountAuthError ? caught.message : fallback);
  const reset = () => { setMode('idle'); setCode(''); setCurrentPassword(''); setNewEmail(''); setError(''); };

  const run = async (action: () => Promise<void>, fallback: string) => {
    setBusy(true);
    setError('');
    try { await action(); } catch (caught) { fail(caught, fallback); } finally { setBusy(false); }
  };

  const sendVerification = () => run(async () => {
    await startEmailVerification(user?.email ?? '');
    setMode('verify');
    setMessage('');
  }, 'Could not send a code.');

  const confirmVerification = (event: FormEvent) => {
    event.preventDefault();
    return run(async () => {
      await confirmEmailVerification(user?.email ?? '', code);
      await refreshUser();
      reset();
      setMessage('Email verified.');
    }, 'Could not verify the email.');
  };

  const requestChange = (event: FormEvent) => {
    event.preventDefault();
    return run(async () => {
      await startEmailChange(newEmail, currentPassword);
      setCurrentPassword('');
      setMode('change-confirm');
    }, 'Could not start the email change.');
  };

  const confirmChange = (event: FormEvent) => {
    event.preventDefault();
    return run(async () => {
      await finishEmailChange(newEmail, code);
      // Changing the address revokes every session, including this one.
      setSignInHint({ email: newEmail.trim(), notice: 'Email changed. Every device was signed out, so sign in with your new address.' });
      setWebSessionActive(false);
      navigate('/sign-in', { replace: true });
    }, 'Could not change the email.');
  };

  return (
    <SettingsCard
      icon={<Mail className="h-5 w-5" />}
      title="Email"
      description={
        <>
          <span className="break-all font-semibold" style={{ color: 'var(--color-text-primary)' }}>{user?.email ?? '—'}</span>
          {user && (verified
            ? <span className="ml-2 inline-flex items-center gap-1 text-xs font-semibold" style={{ color: 'var(--color-success)' }}><BadgeCheck className="h-3.5 w-3.5" />Verified</span>
            : <span className="ml-2 text-xs font-semibold" style={{ color: 'var(--color-warning)' }}>Not verified</span>)}
        </>
      }
      action={mode === 'idle' && user ? (
        <div className="flex flex-col gap-2 sm:items-end">
          {!verified && <SecondaryButton type="button" onClick={() => void sendVerification()} disabled={busy}>Verify email</SecondaryButton>}
          {hasPassword === true && <SecondaryButton type="button" onClick={() => { setError(''); setMessage(''); setMode('change-request'); }}>Change email</SecondaryButton>}
        </div>
      ) : undefined}
    >
      <div className="space-y-4">
        {message && <Notice tone="success">{message}</Notice>}
        {mode === 'idle' && hasPassword === false && <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>Create a password below before changing your email.</p>}
        {mode === 'idle' && error && <Notice tone="error">{error}</Notice>}

        {mode === 'verify' && (
          <form onSubmit={(event) => void confirmVerification(event)} className="max-w-sm space-y-4" noValidate>
            <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>If this request is eligible, an email with a 6-digit code will arrive shortly.</p>
            <CodeField value={code} onChange={setCode} disabled={busy} />
            {error && <Notice tone="error">{error}</Notice>}
            <div className="flex gap-2"><PrimaryButton type="submit" busy={busy} busyLabel="Verifying…" disabled={code.length !== 6}>Verify</PrimaryButton><SecondaryButton type="button" onClick={reset} disabled={busy}>Cancel</SecondaryButton></div>
          </form>
        )}

        {mode === 'change-request' && (
          <form onSubmit={(event) => void requestChange(event)} className="max-w-sm space-y-4" noValidate>
            <EmailField label="New email" value={newEmail} onChange={(event) => setNewEmail(event.target.value)} autoComplete="email" required />
            <PasswordField label="Current password" value={currentPassword} onChange={(event) => setCurrentPassword(event.target.value)} autoComplete="current-password" hint="We email a code to the new address, and a notice to the old one." required />
            {error && <Notice tone="error">{error}</Notice>}
            <div className="flex gap-2"><PrimaryButton type="submit" busy={busy} busyLabel="Sending…" disabled={!newEmail.trim() || !currentPassword}>Email me a code</PrimaryButton><SecondaryButton type="button" onClick={reset} disabled={busy}>Cancel</SecondaryButton></div>
          </form>
        )}

        {mode === 'change-confirm' && (
          <form onSubmit={(event) => void confirmChange(event)} className="max-w-sm space-y-4" noValidate>
            <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>If this request is eligible, a code will arrive at <strong className="break-all">{newEmail.trim()}</strong>. Changing your email signs out every device, including this one.</p>
            <CodeField value={code} onChange={setCode} disabled={busy} />
            {error && <Notice tone="error">{error}</Notice>}
            <div className="flex gap-2"><PrimaryButton type="submit" busy={busy} busyLabel="Changing…" disabled={code.length !== 6}>Change email</PrimaryButton><SecondaryButton type="button" onClick={reset} disabled={busy}>Cancel</SecondaryButton></div>
          </form>
        )}
      </div>
    </SettingsCard>
  );
}
