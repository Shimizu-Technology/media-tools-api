import type { LucideIcon } from 'lucide-react';
import { ArrowRight, Check } from 'lucide-react';
import { motion } from 'framer-motion';
import { Link } from 'react-router-dom';

interface CapturePageHeaderProps {
  icon: LucideIcon;
  eyebrow: string;
  title: string;
  description: string;
  historyTo: string;
  historyLabel: string;
  highlights: string[];
}

/** Shared orientation for each capture workflow. */
export function CapturePageHeader({
  icon: Icon,
  eyebrow,
  title,
  description,
  historyTo,
  historyLabel,
  highlights,
}: CapturePageHeaderProps) {
  return (
    <motion.header
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.4, ease: [0.22, 1, 0.36, 1] }}
      className="mb-8 border-b pb-7 sm:mb-10 sm:pb-8"
      style={{ borderColor: 'var(--color-border-subtle)' }}
    >
      <div className="mb-4 flex items-center justify-between gap-4">
        <div
          className="inline-flex min-h-8 items-center gap-2 rounded-full px-3 text-xs font-semibold uppercase tracking-[0.14em]"
          style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-600)' }}
        >
          <Icon className="h-4 w-4" aria-hidden="true" />
          {eyebrow}
        </div>
        <Link
          to={historyTo}
          className="inline-flex min-h-11 items-center gap-1.5 rounded-xl px-2 text-sm font-semibold"
          style={{ color: 'var(--color-brand-500)' }}
        >
          <span className="hidden sm:inline">{historyLabel}</span>
          <span className="sm:hidden">Library</span>
          <ArrowRight className="h-4 w-4" aria-hidden="true" />
        </Link>
      </div>

      <h1
        className="max-w-3xl text-3xl font-semibold leading-tight tracking-tight sm:text-4xl lg:text-5xl"
        style={{ color: 'var(--color-text-primary)' }}
      >
        {title}
      </h1>
      <p
        className="mt-3 max-w-2xl text-base leading-relaxed sm:text-lg"
        style={{ color: 'var(--color-text-secondary)' }}
      >
        {description}
      </p>

      <ul className="mt-5 flex flex-wrap gap-x-5 gap-y-2" aria-label="Workflow highlights">
        {highlights.map((highlight) => (
          <li
            key={highlight}
            className="inline-flex items-center gap-1.5 text-sm"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            <Check className="h-4 w-4" style={{ color: 'var(--color-brand-500)' }} aria-hidden="true" />
            {highlight}
          </li>
        ))}
      </ul>
    </motion.header>
  );
}
