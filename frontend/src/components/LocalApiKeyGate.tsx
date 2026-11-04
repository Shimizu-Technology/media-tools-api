import { KeyRound } from 'lucide-react';
import { ApiKeySetup } from './ApiKeySetup';

/**
 * Local development only. ProtectedRoute loads this through a branch on
 * `localApiKeyMode`, a constant that is false in production builds, so the
 * bundler drops this file and the API-key setup it renders from the release.
 */
export default function LocalApiKeyGate({ onKeySet }: { onKeySet: () => void }) {
  return (
    <main className="min-h-screen px-4 py-10 flex items-center justify-center" style={{ backgroundColor: 'var(--color-bg)' }}>
      <section className="w-full max-w-xl rounded-xl border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-separator)' }}>
        <div className="mb-5 flex items-start gap-4">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-lg" style={{ backgroundColor: 'var(--color-accent-tint)', color: 'var(--color-accent)' }}>
            <KeyRound className="h-5 w-5" />
          </div>
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-accent)' }}>Development mode</p>
            <h1 className="mt-1 text-2xl font-semibold tracking-tight" style={{ color: 'var(--color-text)' }}>Add an API key to continue.</h1>
            <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
              This build runs in local API-key mode. Production builds sign in with an account instead.
            </p>
          </div>
        </div>
        <ApiKeySetup onKeySet={onKeySet} hasKey={false} />
      </section>
    </main>
  );
}
