import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { Mark } from '../ui/Mark';

/** Centered card used by every signed-out screen. Phone-first: one column, no side chrome. */
export function AuthShell({ title, intro, children, footer }: { title: string; intro?: ReactNode; children: ReactNode; footer?: ReactNode }) {
  return (
    <main className="flex min-h-screen flex-col items-center px-4 py-8 sm:justify-center sm:py-12" style={{ backgroundColor: 'var(--color-bg)', color: 'var(--color-text)' }}>
      <Link to="/" className="mb-6 flex min-h-11 items-center gap-3">
        <Mark size={40} />
        <span className="font-semibold tracking-tight">Media Tools</span>
      </Link>
      <section className="w-full max-w-md rounded-xl border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-separator)' }}>
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
    <Link to={to} state={state} className="inline-flex min-h-11 items-center px-1 font-semibold underline-offset-4 hover:underline" style={{ color: 'var(--color-accent)' }}>
      {children}
    </Link>
  );
}

export function Notice({ tone, children }: { tone: 'error' | 'info' | 'success'; children: ReactNode }) {
  const color = tone === 'error' ? 'var(--color-danger)' : tone === 'success' ? 'var(--color-accent)' : 'var(--color-text-secondary)';
  const background = tone === 'error' ? 'var(--color-fill)' : tone === 'success' ? 'var(--color-accent-tint)' : 'var(--color-fill)';
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} className="rounded-md px-4 py-3 text-sm leading-6" style={{ color, backgroundColor: background }}>
      {children}
    </div>
  );
}
