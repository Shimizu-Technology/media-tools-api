import { useState } from 'react';
import { KeyRound, Loader2 } from 'lucide-react';
import { PasskeyError, passkeysSupported, signInWithPasskey } from '../lib/passkeys';

export function PasskeySignInButton({ onSuccess, className = '' }: { onSuccess?: () => void; className?: string }) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState('');
  const supported = passkeysSupported();

  const signIn = async () => {
    setPending(true);
    setError('');
    try {
      await signInWithPasskey();
      onSuccess?.();
    } catch (caught) {
      if (caught instanceof DOMException && caught.name === 'NotAllowedError') {
        setError('Passkey sign-in was canceled.');
      } else if (caught instanceof PasskeyError) {
        setError(caught.message);
      } else {
        setError('Passkey sign-in did not finish. Please try again.');
      }
    } finally {
      setPending(false);
    }
  };

  return (
    <div>
      <button
        type="button"
        onClick={() => void signIn()}
        disabled={pending || !supported}
        className={`inline-flex min-h-12 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-white transition hover:-translate-y-0.5 disabled:cursor-not-allowed disabled:opacity-60 ${className}`}
        style={{ backgroundColor: 'var(--color-brand-500)' }}
      >
        {pending ? <Loader2 className="h-4 w-4 animate-spin" /> : <KeyRound className="h-4 w-4" />}
        {pending ? 'Checking passkey…' : 'Sign in with a passkey'}
      </button>
      {!supported && <p className="mt-2 text-xs" style={{ color: 'var(--color-text-muted)' }}>Passkeys need a current browser on a secure connection.</p>}
      {error && <p className="mt-2 text-sm" role="alert" style={{ color: 'var(--color-danger)' }}>{error}</p>}
    </div>
  );
}
