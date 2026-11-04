import { useState, type FormEvent } from 'react';
import { KeyRound } from 'lucide-react';
import { useAuthContext } from '../../contexts/useAuthContext';
import { AccountAuthError, changePassword } from '../../lib/accountAuth';
import { Notice } from '../auth/AuthShell';
import { PasswordField, PrimaryButton } from '../auth/fields';
import { SettingsCard } from './SettingsCard';

export function PasswordSection({ configured, onChanged }: { configured: boolean | null; onChanged: () => void }) {
  const { user } = useAuthContext();
  const [current, setCurrent] = useState('');
  const [password, setPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const verified = user?.email_verified === true;
  const mismatch = confirmation.length > 0 && password !== confirmation;

  const save = async (event: FormEvent) => {
    event.preventDefault();
    if (password !== confirmation) { setError('The passwords do not match.'); return; }
    setBusy(true);
    setError('');
    setMessage('');
    try {
      await changePassword(password, configured ? current : undefined);
      setCurrent(''); setPassword(''); setConfirmation('');
      setMessage(configured ? 'Password changed. Your other devices were signed out.' : 'Password created. You can now sign in with your email on any device.');
      onChanged();
    } catch (caught) {
      setError(caught instanceof AccountAuthError ? caught.message : 'Could not save the password.');
    } finally {
      setBusy(false);
    }
  };

  const description = configured === null
    ? 'Checking your password…'
    : configured
      ? 'Change your password. Your other signed-in devices are signed out when you do.'
      : verified
        ? 'Create a password so you can sign in with your email on any device.'
        : 'Verify your email above first. Then you can create a password.';

  return (
    <SettingsCard icon={<KeyRound className="h-5 w-5" />} title="Password" description={description}>
      {configured !== null && (configured || verified) && (
        <form onSubmit={(event) => void save(event)} className="max-w-sm space-y-4" noValidate>
          {configured && <PasswordField label="Current password" value={current} onChange={(event) => setCurrent(event.target.value)} autoComplete="current-password" required />}
          <PasswordField label="New password" value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="new-password" hint="12 to 128 characters." required />
          <PasswordField label="Confirm new password" value={confirmation} onChange={(event) => setConfirmation(event.target.value)} autoComplete="new-password" aria-invalid={mismatch} required />
          {mismatch && <p className="text-xs" style={{ color: 'var(--color-error)' }}>The passwords do not match.</p>}
          {error && <Notice tone="error">{error}</Notice>}
          {message && <Notice tone="success">{message}</Notice>}
          <PrimaryButton type="submit" busy={busy} busyLabel="Saving…" disabled={password.length < 12 || !confirmation || (configured === true && !current)}>
            {configured ? 'Change password' : 'Create password'}
          </PrimaryButton>
        </form>
      )}
    </SettingsCard>
  );
}
