import type { ReactNode } from 'react';

/** The card chrome every Settings section already uses. */
export function SettingsCard({ icon, title, description, children, action }: { icon: ReactNode; title: string; description?: ReactNode; children?: ReactNode; action?: ReactNode }) {
  return (
    <section className="rounded-xl border p-5 sm:p-6" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-separator)' }}>
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex min-w-0 flex-1 items-start gap-4">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-lg" style={{ backgroundColor: 'var(--color-accent-tint)', color: 'var(--color-accent)' }}>{icon}</div>
          <div className="min-w-0 flex-1">
            <h2 className="text-xl font-semibold" style={{ color: 'var(--color-text)' }}>{title}</h2>
            {description && <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{description}</p>}
          </div>
        </div>
        {action && <div className="shrink-0">{action}</div>}
      </div>
      {children && <div className="mt-5">{children}</div>}
    </section>
  );
}
