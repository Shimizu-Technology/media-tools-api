import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { Mark } from '../ui/Mark';
import { Notice as InlineNotice } from '../ui/Field';

/** Every signed-out screen: the mark and name centered, a rounded title, then the form. */
export function AuthShell({ title, intro, children, footer }: { title: string; intro?: ReactNode; children: ReactNode; footer?: ReactNode }) {
  return (
    <main className="flex min-h-dvh flex-col items-center bg-background px-5 pb-[max(2rem,env(safe-area-inset-bottom))] pt-[max(2rem,env(safe-area-inset-top))] text-text sm:justify-center sm:py-12">
      <Link to="/" className="flex flex-col items-center gap-3 rounded-lg px-2 py-2" aria-label="Media Tools home">
        <Mark size={64} />
        <span className="font-display text-xl font-extrabold tracking-[-0.01em]">Media Tools</span>
      </Link>
      <section className="mt-8 w-full max-w-sm sm:max-w-md sm:rounded-xl sm:bg-surface sm:p-8 sm:shadow-raised">
        <h1 className="text-large-title">{title}</h1>
        {intro && <p className="mt-2 text-callout text-text-secondary">{intro}</p>}
        <div className="mt-6">{children}</div>
      </section>
      {footer && <div className="mt-6 w-full max-w-sm text-center text-callout text-text-secondary">{footer}</div>}
    </main>
  );
}

/** Inline link that still meets the 44px touch target on a phone. */
export function AuthLink({ to, state, children }: { to: string; state?: unknown; children: ReactNode }) {
  return (
    <Link to={to} state={state} className="inline-flex min-h-11 items-center px-1 font-semibold text-accent-text underline-offset-4 hover:underline">
      {children}
    </Link>
  );
}

export function Notice({ tone, children }: { tone: 'error' | 'info' | 'success'; children: ReactNode }) {
  return <InlineNotice tone={tone}>{children}</InlineNotice>;
}
