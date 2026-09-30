import { useEffect, useRef, useState } from 'react';
import { KeyRound, Loader2, ShieldCheck, X } from 'lucide-react';
import { prepareRecoveryCodeSignIn, RecoveryCodeError, signInWithRecoveryCode } from '../lib/recoveryCodes';

export function RecoveryCodeSignIn({ className = '', onSuccess }: { className?: string; onSuccess?: () => void }) {
  const [open, setOpen] = useState(false);
  const [preparing, setPreparing] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [code, setCode] = useState('');
  const [error, setError] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (open && !preparing) inputRef.current?.focus();
  }, [open, preparing]);

  const begin = async () => {
    setOpen(true);
    setPreparing(true);
    setError('');
    try {
      if (await prepareRecoveryCodeSignIn()) {
        setOpen(false);
        onSuccess?.();
      }
    } catch (caught) {
      setError(caught instanceof RecoveryCodeError ? caught.message : 'Could not prepare recovery sign-in.');
    } finally {
      setPreparing(false);
    }
  };

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setSubmitting(true);
    setError('');
    try {
      await signInWithRecoveryCode(code);
      setCode('');
      setOpen(false);
      onSuccess?.();
    } catch (caught) {
      setError(caught instanceof RecoveryCodeError ? caught.message : 'Could not complete recovery sign-in.');
    } finally {
      setSubmitting(false);
    }
  };

  const close = () => {
  if (preparing || submitting) return;
    setCode('');
    setError('');
    setOpen(false);
  };

  return (
    <>
      <button type="button" onClick={() => void begin()} className={`inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-5 py-3 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)] ${className}`} style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
        <KeyRound className="h-4 w-4" />Use a recovery code
      </button>
      {open && (
        <div className="fixed inset-0 z-[100] flex items-center justify-center overflow-y-auto bg-black/70 p-4" role="presentation">
          <section role="dialog" aria-modal="true" aria-labelledby="recovery-sign-in-title" className="my-auto w-full max-w-md rounded-[2rem] border p-6 shadow-2xl sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
            <div className="flex items-start justify-between gap-4">
              <div className="flex h-12 w-12 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}><ShieldCheck className="h-5 w-5" /></div>
              <button type="button" onClick={close} disabled={preparing || submitting} aria-label="Cancel recovery sign-in" className="flex h-11 w-11 items-center justify-center rounded-xl transition hover:bg-[var(--color-nav-hover)] disabled:opacity-50"><X className="h-5 w-5" /></button>
            </div>
            <h2 id="recovery-sign-in-title" className="mt-5 text-2xl font-semibold tracking-tight">Use a saved recovery code</h2>
            <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>Enter one unused code from the set you saved. The code works once and stays only in this form while you sign in.</p>
            {preparing ? (
              <div className="mt-6 flex min-h-24 items-center justify-center gap-3" role="status" style={{ color: 'var(--color-text-secondary)' }}><Loader2 className="h-5 w-5 animate-spin" />Preparing secure sign-in…</div>
            ) : (
              <form onSubmit={(event) => void submit(event)} className="mt-6">
                <label htmlFor="recovery-code" className="text-sm font-semibold">Recovery code</label>
                <input ref={inputRef} id="recovery-code" name="recovery-code" value={code} onChange={(event) => { setCode(event.target.value); if (error) setError(''); }} autoComplete="off" autoCapitalize="characters" spellCheck={false} placeholder="MTR-XXXX-XXXX-…" className="mt-2 min-h-12 w-full rounded-xl border bg-transparent px-4 font-mono text-sm uppercase outline-none focus:ring-2 focus:ring-[var(--color-brand-500)]" style={{ borderColor: 'var(--color-border)' }} />
                {error && <p className="mt-3 text-sm" role="alert" style={{ color: 'var(--color-danger)' }}>{error}</p>}
                <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
                  <button type="button" onClick={close} disabled={submitting} className="min-h-11 rounded-xl border px-5 text-sm font-semibold disabled:opacity-50" style={{ borderColor: 'var(--color-border)' }}>Cancel</button>
                  <button type="submit" disabled={submitting || !code.trim()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-white disabled:opacity-50" style={{ backgroundColor: 'var(--color-brand-500)' }}>{submitting && <Loader2 className="h-4 w-4 animate-spin" />}{submitting ? 'Signing in…' : 'Sign in securely'}</button>
                </div>
              </form>
            )}
          </section>
        </div>
      )}
    </>
  );
}
