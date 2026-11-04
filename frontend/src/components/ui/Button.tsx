import type { ButtonHTMLAttributes, ReactNode } from 'react';
import { Link, type LinkProps } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { buttonClass, type ButtonSize, type ButtonVariant } from './styles';

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant;
  size?: ButtonSize;
  block?: boolean;
  busy?: boolean;
  icon?: ReactNode;
};

export function Button({ variant, size, block, busy = false, icon, className, children, disabled, type = 'button', ...rest }: ButtonProps) {
  return (
    <button type={type} disabled={disabled || busy} aria-busy={busy || undefined} className={buttonClass({ variant, size, block, className })} {...rest}>
      {busy ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" /> : icon}
      {children}
    </button>
  );
}

type ButtonLinkProps = LinkProps & { variant?: ButtonVariant; size?: ButtonSize; block?: boolean; icon?: ReactNode };

export function ButtonLink({ variant, size, block, icon, className, children, ...rest }: ButtonLinkProps) {
  return (
    <Link className={buttonClass({ variant, size, block, className: typeof className === 'string' ? className : '' })} {...rest}>
      {icon}
      {children}
    </Link>
  );
}

type IconButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & { label: string; tone?: 'accent' | 'neutral' };

/** A 44px square for a single icon. The label is required: it is the accessible name. */
export function IconButton({ label, tone = 'accent', className = '', children, type = 'button', ...rest }: IconButtonProps) {
  return (
    <button type={type} aria-label={label} title={label} className={`pressable inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-full hover:bg-fill disabled:opacity-40 ${tone === 'accent' ? 'text-accent-text' : 'text-text-secondary'} ${className}`} {...rest}>
      {children}
    </button>
  );
}
