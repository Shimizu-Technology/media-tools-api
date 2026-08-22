import { ArrowRight, ShieldCheck, Trash2 } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';

/** Explains the cross-platform deletion path for people and store reviewers. */
export function DeleteAccountPage() {
  const { isAuthenticated } = useAuthContext();

  return (
    <main className="mx-auto max-w-3xl px-4 py-16 sm:py-24">
      <div className="rounded-[2rem] border p-6 sm:p-10" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex h-14 w-14 items-center justify-center rounded-2xl" style={{ backgroundColor: 'color-mix(in srgb, var(--color-error) 12%, transparent)', color: 'var(--color-error)' }}>
          <Trash2 className="h-6 w-6" />
        </div>
        <p className="mt-6 text-xs font-semibold uppercase tracking-[0.2em]" style={{ color: 'var(--color-brand-500)' }}>Account controls</p>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl" style={{ color: 'var(--color-text-primary)' }}>Delete your Media Tools account</h1>
        <p className="mt-4 text-base leading-7" style={{ color: 'var(--color-text-secondary)' }}>
          You can permanently delete your account from Media Tools on the web or in the iPhone app. The same verified process removes account-owned recordings, transcripts, PDFs, summaries, chats, collections, webhooks, developer keys, and your sign-in identity.
        </p>

        <div className="mt-8 space-y-4 rounded-2xl border p-5" style={{ backgroundColor: 'var(--color-surface-subtle)', borderColor: 'var(--color-border)' }}>
          <div className="flex gap-3">
            <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0" style={{ color: 'var(--color-brand-500)' }} />
            <div>
              <h2 className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>How deletion works</h2>
              <ol className="mt-2 list-decimal space-y-2 pl-5 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
                <li>Sign in to verify that the account belongs to you.</li>
                <li>Open Settings, choose Delete account, and type DELETE.</li>
                <li>Application data is purged immediately. Secure storage and identity-provider cleanup continue automatically if a provider is temporarily unavailable.</li>
              </ol>
            </div>
          </div>
        </div>

        <p className="mt-6 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
          Deletion cannot be undone. Export anything you want to keep first. On iPhone, device recordings owned by the deleted account are removed as part of the process.
        </p>

        <Link to={isAuthenticated ? '/app/settings' : '/app'} className="mt-8 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold transition hover:opacity-90 sm:w-auto" style={{ backgroundColor: 'var(--color-brand-500)', color: 'var(--color-on-brand)' }}>
          {isAuthenticated ? 'Open account settings' : 'Sign in to delete account'}
          <ArrowRight className="h-4 w-4" />
        </Link>
      </div>
    </main>
  );
}
