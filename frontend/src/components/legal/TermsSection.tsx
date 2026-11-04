import type { ReactNode } from 'react';

interface TermsSectionProps {
  title: string;
  children: ReactNode;
}

/** Groups one titled provision within the public Terms of Use. */
export function TermsSection({ title, children }: TermsSectionProps) {
  return (
    <section>
      <h2 className="mb-2 text-heading">
        {title}
      </h2>
      <div>{children}</div>
    </section>
  );
}
