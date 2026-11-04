import type { ReactNode } from 'react';

/** One Settings section: a heading, a sentence, its controls. Hairlines, not cards. */
export function SettingsCard({ title, description, children, action, id }: { title: string; description?: ReactNode; children?: ReactNode; action?: ReactNode; id?: string }) {
  return (
    <section id={id} className="border-t border-separator py-6 first:border-t-0 first:pt-2">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 flex-1">
          <h2 className="text-heading">{title}</h2>
          {description && <div className="mt-1 max-w-[60ch] text-callout text-text-secondary">{description}</div>}
        </div>
        {/* On phones a text-only action lines up with the text above it. */}
        {action && <div className="shrink-0 max-sm:[&>.text-accent]:-ml-4 max-sm:[&>.text-danger]:-ml-4">{action}</div>}
      </div>
      {children && <div className="mt-4">{children}</div>}
    </section>
  );
}
