import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { Mic } from 'lucide-react';

const card = 'pressable flex w-full items-center gap-3.5 rounded-xl bg-hero p-4 text-left text-on-hero shadow-raised hover:opacity-95';

function Content({ hint }: { hint: ReactNode }) {
  return (
    <>
      <span className="flex h-[3.625rem] w-[3.625rem] shrink-0 items-center justify-center rounded-full bg-on-hero text-hero-glyph">
        <Mic className="h-7 w-7" aria-hidden="true" />
      </span>
      <span className="min-w-0">
        <span className="block font-display text-[1.375rem] font-extrabold leading-7 tracking-[-0.01em]">Record</span>
        <span className="block text-callout font-medium">{hint}</span>
      </span>
    </>
  );
}

/** The big Record card: a link from Home, a button where recording starts in place. */
export function RecordCard({ to, onClick, hint }: { to?: string; onClick?: () => void; hint: ReactNode }) {
  if (to) return <Link to={to} className={card}><Content hint={hint} /></Link>;
  return <button type="button" onClick={onClick} className={card}><Content hint={hint} /></button>;
}
