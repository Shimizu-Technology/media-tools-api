import { useEffect, useState } from 'react';
import { AlertTriangle, LoaderCircle, Trash2 } from 'lucide-react';
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
    <section className="rounded-xl border p-6" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'color-mix(in srgb, var(--color-danger) 38%, var(--color-separator))' }}>
      <div className="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex items-start gap-4">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-lg" style={{ backgroundColor: 'color-mix(in srgb, var(--color-danger) 12%, transparent)', color: 'var(--color-danger)' }}>
            <AlertTriangle className="h-5 w-5" />
          </div>
          <div>
            <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text)' }}>Delete account</h2>
            <p className="mt-2 max-w-2xl text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
              Permanently remove your recordings, transcripts, PDFs, chats, collections, webhooks, developer keys, and sign-in account. This cannot be undone.
            </p>
          </div>
        </div>
        {!isOpen && (
          <button type="button" onClick={() => setIsOpen(true)} className="inline-flex min-h-11 shrink-0 items-center justify-center gap-2 rounded-md border px-4 text-sm font-semibold transition-colors hover:bg-[var(--color-fill)]" style={{ borderColor: 'color-mix(in srgb, var(--color-danger) 48%, var(--color-separator))', color: 'var(--color-danger)' }}>
            <Trash2 className="h-4 w-4" />
            Delete account
          </button>
        )}
      </div>

      {isOpen && (
        <div className="mt-6 rounded-lg border p-4" style={{ borderColor: 'color-mix(in srgb, var(--color-danger) 42%, var(--color-separator))', backgroundColor: 'var(--color-fill)' }}>
          <p className="text-sm font-semibold" style={{ color: 'var(--color-text)' }}>Type DELETE to confirm permanent deletion.</p>
          <p className="mt-1 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>Application data is purged immediately. Secure storage and identity-provider cleanup continue durably in the background.</p>
          <label className="mt-4 block text-xs font-semibold uppercase tracking-[0.16em]" style={{ color: 'var(--color-text-secondary)' }} htmlFor="delete-account-confirmation">Confirmation</label>
          <input id="delete-account-confirmation" value={confirmation} onChange={(event) => setConfirmation(event.target.value.toUpperCase())} disabled={isDeleting} autoComplete="off" className="mt-2 min-h-11 w-full rounded-md border bg-transparent px-3 font-mono text-sm outline-none transition-colors focus:ring-2" style={{ borderColor: 'var(--color-separator)', color: 'var(--color-text)' }} placeholder="DELETE" />
          {needsPassword && <div className="mt-4"><PasswordField label="Current password" value={password} onChange={(event) => setPassword(event.target.value)} disabled={isDeleting} autoComplete="current-password" hint="If your account has no password yet, leave this blank." /></div>}
          {error && <p role="alert" className="mt-3 text-sm" style={{ color: 'var(--color-danger)' }}>{error}</p>}
          <div className="mt-4 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
            <button type="button" disabled={isDeleting} onClick={() => { setIsOpen(false); setConfirmation(''); setPassword(''); setError(null); }} className="min-h-11 rounded-md px-4 text-sm font-semibold" style={{ color: 'var(--color-text-secondary)' }}>Cancel</button>
            <button type="button" disabled={confirmation !== 'DELETE' || isDeleting || (passwordState === 'required' && !password)} onClick={() => void permanentlyDelete()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-md px-4 text-sm font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-45" style={{ backgroundColor: 'var(--color-danger)', color: 'var(--color-on-accent)' }}>
              {isDeleting ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
              {isDeleting ? 'Deleting…' : 'Permanently delete account'}
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
