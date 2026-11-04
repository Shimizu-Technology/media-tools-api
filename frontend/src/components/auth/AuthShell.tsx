import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { FileText } from 'lucide-react';

/** Centered card used by every signed-out screen. Phone-first: one column, no side chrome. */
export function AuthShell({ title, intro, children, footer }: { title: string; intro?: ReactNode; children: ReactNode; footer?: ReactNode }) {
  return (
    <main className="flex min-h-screen flex-col items-center px-4 py-8 sm:justify-center sm:py-12" style={{ backgroundColor: 'var(--color-surface)', color: 'var(--color-text-primary)' }}>
      <Link to="/" className="mb-6 flex min-h-11 items-center gap-3">
        <span className="flex h-10 w-10 items-center justify-center rounded-xl" style={{ backgroundColor: 'var(--color-brand-500)' }}>
          <FileText className="h-5 w-5" style={{ color: 'var(--color-on-brand)' }} />
        </span>
        <span className="font-semibold tracking-tight">Media Tools</span>
      </Link>
      <section className="w-full max-w-md rounded-[2rem] border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
        {intro && <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{intro}</p>}
        <div className="mt-6">{children}</div>
      </section>
      {footer && <div className="mt-5 w-full max-w-md text-center text-sm" style={{ color: 'var(--color-text-secondary)' }}>{footer}</div>}
    </main>
  );
}

/** Inline link that still meets the 44px touch target on a phone. */
export function AuthLink({ to, state, children }: { to: string; state?: unknown; children: ReactNode }) {
  return (
    <Link to={to} state={state} className="inline-flex min-h-11 items-center px-1 font-semibold underline-offset-4 hover:underline" style={{ color: 'var(--color-brand-500)' }}>
      {children}
    </Link>
  );
}

export function Notice({ tone, children }: { tone: 'error' | 'info' | 'success'; children: ReactNode }) {
  const color = tone === 'error' ? 'var(--color-error)' : tone === 'success' ? 'var(--color-success)' : 'var(--color-text-secondary)';
  const background = tone === 'error' ? 'var(--color-error-soft)' : tone === 'success' ? 'var(--color-success-subtle)' : 'var(--color-surface-subtle)';
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} className="rounded-xl px-4 py-3 text-sm leading-6" style={{ color, backgroundColor: background }}>
      {children}
    </div>
  );
}
