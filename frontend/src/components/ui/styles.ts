/** Class builders shared by the button primitives and links styled as buttons. */
export type ButtonVariant = 'primary' | 'secondary' | 'plain' | 'danger' | 'danger-plain';
export type ButtonSize = 'md' | 'lg';

const base = 'pressable inline-flex select-none items-center justify-center gap-2 font-semibold whitespace-nowrap disabled:cursor-not-allowed disabled:opacity-50 aria-disabled:cursor-not-allowed aria-disabled:opacity-50';

const variants: Record<ButtonVariant, string> = {
  primary: 'bg-accent-fill text-on-accent hover:opacity-90',
  secondary: 'bg-surface-2 text-text hover:opacity-90',
  plain: 'text-accent-text hover:bg-fill',
  danger: 'bg-danger text-on-danger hover:opacity-90',
  'danger-plain': 'text-danger hover:bg-fill',
};

const sizes: Record<ButtonSize, string> = {
  // 44px: the smallest touch target in the app.
  md: 'min-h-11 px-4 text-callout',
  // The full-width record pill and other one-per-screen actions.
  lg: 'min-h-14 px-6 text-[1.0625rem]',
};

export function buttonClass({ variant = 'secondary', size = 'md', block = false, className = '' }: { variant?: ButtonVariant; size?: ButtonSize; block?: boolean; className?: string } = {}) {
  // A caller's own radius wins; buttons are pills.
  const radius = /(^|\s)rounded-/.test(className) ? '' : 'rounded-full';
  return [base, variants[variant], sizes[size], radius, block ? 'w-full' : '', className].filter(Boolean).join(' ');
}

export function iconLinkClass(tone: 'accent' | 'neutral' = 'accent') {
  return `pressable inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-full hover:bg-fill ${tone === 'accent' ? 'text-accent-text' : 'text-text-secondary'}`;
}

/** Text inputs: 16px or more (index.css enforces it), 44px tall. */
export const inputClass = 'min-h-11 w-full rounded-md border border-transparent bg-surface-2 px-3.5 text-text placeholder:text-text-secondary outline-none transition-colors focus:border-accent-text disabled:opacity-60';
