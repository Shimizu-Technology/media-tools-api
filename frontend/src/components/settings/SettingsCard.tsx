import type { ReactNode } from 'react';

/** One Settings section on its own card: a heading, a sentence, its controls. */
export function SettingsCard({ title, description, children, action, id }: { title: string; description?: ReactNode; children?: ReactNode; action?: ReactNode; id?: string }) {
  return (
    <section id={id} className="mt-3 rounded-lg bg-surface p-4 first:mt-0">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 flex-1">
          <h2 className="text-subheading">{title}</h2>
          {description && <div className="mt-1 max-w-[60ch] text-callout text-text-secondary">{description}</div>}
        </div>
        {/* On phones a text-only action lines up with the text above it. */}
        {action && <div className="shrink-0 max-sm:[&>.text-accent-text]:-ml-4 max-sm:[&>.text-danger]:-ml-4">{action}</div>}
      </div>
      {children && <div className="mt-4">{children}</div>}
    </section>
  );
}
