import { useState } from 'react';

import { transferJoinFragmentBeforeApp, type JoinTransferResult } from '../lib/onboarding';

export function JoinTransferFailure({ initial }: { initial: Extract<JoinTransferResult, { state: 'failed' }> }) {
  const [failure, setFailure] = useState(initial);
  const [retrying, setRetrying] = useState(false);

  const retry = async () => {
    setRetrying(true);
    const result = await transferJoinFragmentBeforeApp();
    if (result.state === 'transferred' || result.state === 'none') {
      window.location.reload();
      return;
    }
    if (result.state === 'failed') setFailure(result);
    setRetrying(false);
  };

  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10" style={{ backgroundColor: 'var(--color-surface)' }}>
      <section className="w-full max-w-lg rounded-[2rem] border p-7 text-center sm:p-9" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <p className="text-xs font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-brand-500)' }}>Secure account setup</p>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>We could not secure this link yet.</h1>
        <p className="mt-3 text-sm leading-6" role="alert" style={{ color: 'var(--color-text-secondary)' }}>{failure.message}</p>
        <button type="button" onClick={() => void retry()} disabled={retrying} className="mt-6 min-h-12 w-full rounded-xl px-5 text-sm font-semibold text-white disabled:opacity-60" style={{ backgroundColor: 'var(--color-brand-500)' }}>{retrying ? 'Securing link…' : 'Try again'}</button>
      </section>
    </main>
  );
}
