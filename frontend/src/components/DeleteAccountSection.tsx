import { useState } from 'react';
import { useClerk } from '@clerk/clerk-react';
import { AlertTriangle, LoaderCircle, Trash2 } from 'lucide-react';
import { deleteAccount, getErrorMessage } from '../lib/api';

const accountStorageKeys = [
  'mta_active_audio_transcription_id',
  'mta_api_key',
  'mta_jwt_token',
  'mta_transcript_ids',
];

function clearLocalAccountState() {
  for (const key of accountStorageKeys) {
    localStorage.removeItem(key);
  }
}

/**
 * Presents Media Tools' destructive account-deletion confirmation and routes
 * the request through the application purge before Clerk sign-out.
 */
export function DeleteAccountSection() {
  const { signOut } = useClerk();
  const [isOpen, setIsOpen] = useState(false);
  const [confirmation, setConfirmation] = useState('');
  const [isDeleting, setIsDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const permanentlyDelete = async () => {
    if (confirmation !== 'DELETE') return;
    setIsDeleting(true);
    setError(null);
    try {
      await deleteAccount('DELETE');
      clearLocalAccountState();
      try {
        await signOut({ redirectUrl: '/' });
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
    <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'color-mix(in srgb, var(--color-error) 38%, var(--color-border))' }}>
      <div className="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex items-start gap-4">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'color-mix(in srgb, var(--color-error) 12%, transparent)', color: 'var(--color-error)' }}>
            <AlertTriangle className="h-5 w-5" />
          </div>
          <div>
            <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>Delete account</h2>
            <p className="mt-2 max-w-2xl text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
              Permanently remove your recordings, transcripts, PDFs, chats, collections, webhooks, developer keys, and sign-in account. This cannot be undone.
            </p>
          </div>
        </div>
        {!isOpen && (
          <button type="button" onClick={() => setIsOpen(true)} className="inline-flex min-h-11 shrink-0 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold transition hover:bg-[var(--color-error-soft)]" style={{ borderColor: 'color-mix(in srgb, var(--color-error) 48%, var(--color-border))', color: 'var(--color-error)' }}>
            <Trash2 className="h-4 w-4" />
            Delete account
          </button>
        )}
      </div>

      {isOpen && (
        <div className="mt-6 rounded-2xl border p-4" style={{ borderColor: 'color-mix(in srgb, var(--color-error) 42%, var(--color-border))', backgroundColor: 'var(--color-surface-subtle)' }}>
          <p className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>Type DELETE to confirm permanent deletion.</p>
          <p className="mt-1 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>Application data is purged immediately. Secure storage and identity-provider cleanup continue durably in the background.</p>
          <label className="mt-4 block text-xs font-semibold uppercase tracking-[0.16em]" style={{ color: 'var(--color-text-muted)' }} htmlFor="delete-account-confirmation">Confirmation</label>
          <input id="delete-account-confirmation" value={confirmation} onChange={(event) => setConfirmation(event.target.value.toUpperCase())} disabled={isDeleting} autoComplete="off" className="mt-2 min-h-11 w-full rounded-xl border bg-transparent px-3 font-mono text-sm outline-none transition focus:ring-2" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }} placeholder="DELETE" />
          {error && <p role="alert" className="mt-3 text-sm" style={{ color: 'var(--color-error)' }}>{error}</p>}
          <div className="mt-4 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
            <button type="button" disabled={isDeleting} onClick={() => { setIsOpen(false); setConfirmation(''); setError(null); }} className="min-h-11 rounded-xl px-4 text-sm font-semibold" style={{ color: 'var(--color-text-secondary)' }}>Cancel</button>
            <button type="button" disabled={confirmation !== 'DELETE' || isDeleting} onClick={() => void permanentlyDelete()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 text-sm font-semibold transition disabled:cursor-not-allowed disabled:opacity-45" style={{ backgroundColor: 'var(--color-error)', color: 'var(--color-on-brand)' }}>
              {isDeleting ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
              {isDeleting ? 'Deleting…' : 'Permanently delete account'}
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
