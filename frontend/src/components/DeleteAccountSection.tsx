import { useEffect, useState } from 'react';
import { Trash2 } from 'lucide-react';
import { SettingsCard } from './settings/SettingsCard';
import { Button } from './ui/Button';
import { Input, Notice } from './ui/Field';
import { deleteAccount, getErrorMessage } from '../lib/api';
import { useAuthContext } from '../contexts/useAuthContext';
import { getPasswordStatus } from '../lib/accountAuth';
import { PasswordField } from './auth/fields';

const accountStorageKeys = [
  'mta_active_audio_transcription_id',
  'mta_api_key',
  'mta_transcript_ids',
];

function clearLocalAccountState() {
  for (const key of accountStorageKeys) {
    localStorage.removeItem(key);
  }
}

/**
 * Presents Media Tools' destructive account-deletion confirmation and routes
 * the request through the application purge before signing out.
 */
export function DeleteAccountSection() {
  const { signOut } = useAuthContext();
  const [isOpen, setIsOpen] = useState(false);
  const [confirmation, setConfirmation] = useState('');
  const [isDeleting, setIsDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [password, setPassword] = useState('');
  // Accounts with a password must re-enter it. If the check fails, offer the
  // field anyway: the server remains the authority and rejects a missing password.
  const [passwordState, setPasswordState] = useState<'unknown' | 'required' | 'none'>('unknown');
  const needsPassword = passwordState !== 'none';

  useEffect(() => {
    if (!isOpen) return;
    let cancelled = false;
    getPasswordStatus().then((status) => { if (!cancelled) setPasswordState(status.configured ? 'required' : 'none'); }).catch(() => undefined);
    return () => { cancelled = true; };
  }, [isOpen]);

  const permanentlyDelete = async () => {
    if (confirmation !== 'DELETE' || (passwordState === 'required' && !password)) return;
    setIsDeleting(true);
    setError(null);
    try {
      await deleteAccount('DELETE', password || undefined);
      clearLocalAccountState();
      try {
        await signOut();
      } catch {
        setError('Your account deletion is underway, but this browser could not finish signing out. Close this tab and reopen Media Tools.');
        setIsDeleting(false);
      }
    } catch (caught) {
      setError(getErrorMessage(caught));
      setIsDeleting(false);
    }
  };

  return (
    <SettingsCard
      title="Delete account"
      description="Permanently remove your recordings, transcripts, PDFs, chats, collections, webhooks, developer keys, and sign-in account. This cannot be undone."
      action={!isOpen ? <Button variant="danger-plain" onClick={() => setIsOpen(true)} icon={<Trash2 className="h-4 w-4" />}>Delete account</Button> : undefined}
    >
      {isOpen && (
        <div className="rounded-lg border border-separator bg-surface p-4">
          <p className="text-callout font-semibold">Type DELETE to confirm permanent deletion.</p>
          <p className="mt-1 text-callout text-text-secondary">Application data is purged immediately. Secure storage and identity-provider cleanup continue durably in the background.</p>
          <label className="mt-4 block text-callout font-semibold" htmlFor="delete-account-confirmation">Confirmation</label>
          <Input id="delete-account-confirmation" value={confirmation} onChange={(event) => setConfirmation(event.target.value.toUpperCase())} disabled={isDeleting} autoComplete="off" className="mt-1.5 font-mono" placeholder="DELETE" />
          {needsPassword && <div className="mt-4"><PasswordField label="Current password" value={password} onChange={(event) => setPassword(event.target.value)} disabled={isDeleting} autoComplete="current-password" hint="If your account has no password yet, leave this blank." /></div>}
          {error && <div className="mt-3"><Notice tone="error">{error}</Notice></div>}
          <div className="mt-4 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <Button variant="plain" disabled={isDeleting} onClick={() => { setIsOpen(false); setConfirmation(''); setPassword(''); setError(null); }}>Cancel</Button>
            <Button variant="danger" disabled={confirmation !== 'DELETE' || (passwordState === 'required' && !password)} busy={isDeleting} onClick={() => void permanentlyDelete()} icon={<Trash2 className="h-4 w-4" />}>
              {isDeleting ? 'Deleting…' : 'Permanently delete account'}
            </Button>
          </div>
        </div>
      )}
    </SettingsCard>
  );
}
