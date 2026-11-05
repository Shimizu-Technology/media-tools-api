import { ApiKeySetup } from './ApiKeySetup';

/**
 * Local development only. ProtectedRoute loads this through a branch on
 * `localApiKeyMode`, a constant that is false in production builds, so the
 * bundler drops this file and the API-key setup it renders from the release.
 */
export default function LocalApiKeyGate({ onKeySet }: { onKeySet: () => void }) {
  return (
    <main className="min-h-screen px-4 py-10 flex items-center justify-center" style={{ backgroundColor: 'var(--color-background)' }}>
      <section className="w-full max-w-xl rounded-xl border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-separator)' }}>
        <div className="mb-5 flex items-start gap-4">
          <div>
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
