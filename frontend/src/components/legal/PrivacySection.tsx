import type { ReactNode } from 'react';

interface PrivacySectionProps {
  title: string;
  children: ReactNode;
}

/** Groups one titled disclosure within the public Privacy Policy. */
export function PrivacySection({ title, children }: PrivacySectionProps) {
  return (
    <section>
      <h2 className="mb-3 text-lg font-semibold" style={{ color: 'var(--color-text-primary)' }}>
        {title}
      </h2>
      <div className="leading-relaxed">{children}</div>
    </section>
  );
}
