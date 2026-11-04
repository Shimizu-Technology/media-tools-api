import type { ReactNode } from 'react';

interface SupportCardProps {
  title: string;
  children: ReactNode;
}

/** Presents one focused support topic in the public support resource. */
export function SupportCard({ title, children }: SupportCardProps) {
  return (
    <section>
      <h2 className="text-heading">
        {title}
      </h2>
      <div className="mt-2">
        {children}
      </div>
    </section>
  );
}
