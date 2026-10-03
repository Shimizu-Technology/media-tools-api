import { useEffect, useRef, useState } from 'react';
import { Loader2, LockKeyhole, Mail, X } from 'lucide-react';
import { PasswordError, signInWithPassword } from '../lib/passwords';

export function PasswordSignIn({ onSuccess, className = '' }: { onSuccess?: () => void; className?: string }) {
  const [open, setOpen] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const emailRef = useRef<HTMLInputElement>(null);
  useEffect(() => { if (open) emailRef.current?.focus(); }, [open]);

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setSubmitting(true); setError('');
    try {
      await signInWithPassword(email, password);
      setPassword(''); setOpen(false); onSuccess?.();
    } catch (caught) {
      setError(caught instanceof PasswordError ? caught.message : 'Could not sign in.');
    } finally { setSubmitting(false); }
  };

  return <>
    <button type="button" onClick={() => setOpen(true)} className={`inline-flex min-h-12 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-white ${className}`} style={{ backgroundColor: 'var(--color-brand-500)' }}>
      <Mail className="h-4 w-4" />Sign in with email
    </button>
    {open && <div className="fixed inset-0 z-[100] flex items-center justify-center overflow-y-auto bg-black/70 p-4" role="presentation">
      <section role="dialog" aria-modal="true" aria-labelledby="password-sign-in-title" className="my-auto w-full max-w-md rounded-[2rem] border p-6 shadow-2xl sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex items-start justify-between gap-4">
          <div className="flex h-12 w-12 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}><LockKeyhole className="h-5 w-5" /></div>
          <button type="button" onClick={() => { if (!submitting) { setOpen(false); setPassword(''); setError(''); } }} disabled={submitting} aria-label="Cancel password sign-in" className="flex h-11 w-11 items-center justify-center rounded-xl"><X className="h-5 w-5" /></button>
        </div>
        <h2 id="password-sign-in-title" className="mt-5 text-2xl font-semibold tracking-tight">Sign in with email</h2>
        <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>Use the Media Tools password you created. This browser stays signed in until you sign out or revoke it.</p>
        <form onSubmit={(event) => void submit(event)} className="mt-6 space-y-4">
          <label className="block text-sm font-semibold" htmlFor="password-email">Email<input ref={emailRef} id="password-email" type="email" autoComplete="username" value={email} onChange={(event) => setEmail(event.target.value)} className="mt-2 min-h-12 w-full rounded-xl border bg-transparent px-4 outline-none" style={{ borderColor: 'var(--color-border)' }} /></label>
          <label className="block text-sm font-semibold" htmlFor="password-value">Password<input id="password-value" type="password" autoComplete="current-password" value={password} onChange={(event) => { setPassword(event.target.value); if (error) setError(''); }} className="mt-2 min-h-12 w-full rounded-xl border bg-transparent px-4 outline-none" style={{ borderColor: 'var(--color-border)' }} /></label>
          {error && <p className="text-sm" role="alert" style={{ color: 'var(--color-danger)' }}>{error}</p>}
          <button type="submit" disabled={submitting || !email.trim() || !password} className="inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-white disabled:opacity-50" style={{ backgroundColor: 'var(--color-brand-500)' }}>{submitting && <Loader2 className="h-4 w-4 animate-spin" />}{submitting ? 'Signing in…' : 'Sign in'}</button>
        </form>
      </section>
    </div>}
  </>;
}
