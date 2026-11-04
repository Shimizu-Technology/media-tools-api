import type { ReactNode } from 'react';

interface SupportCardProps {
  title: string;
  children: ReactNode;
}

/** Presents one focused support topic in the public support resource. */
export function SupportCard({ title, children }: SupportCardProps) {
  return (
    <section
      className="rounded-lg border p-5"
      style={{
        backgroundColor: 'var(--color-surface)',
        borderColor: 'var(--color-separator)',
      }}
    >
      <h2
        className="text-lg font-semibold"
        style={{ color: 'var(--color-text)' }}
      >
        {title}
      </h2>
      <div
        className="mt-3 leading-7"
        style={{ color: 'var(--color-text-secondary)' }}
      >
        {children}
      </div>
    </section>
  );
}
