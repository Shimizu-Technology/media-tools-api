import type { ReactNode } from 'react';

interface PrivacySectionProps {
  title: string;
  children: ReactNode;
}

/** Groups one titled disclosure within the public Privacy Policy. */
export function PrivacySection({ title, children }: PrivacySectionProps) {
  return (
    <section>
      <h2 className="mb-2 text-heading">
        {title}
      </h2>
      <div>{children}</div>
    </section>
  );
}
