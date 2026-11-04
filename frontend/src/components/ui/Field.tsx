import type { ComponentProps, ReactNode } from 'react';
import { AlertCircle, CheckCircle2, Info } from 'lucide-react';
import { inputClass } from './styles';


/** A plain text input at 16px or more, 44px tall. */
export function Input({ className = '', ...rest }: ComponentProps<'input'>) {
  return <input className={`${inputClass} ${className}`} {...rest} />;
}

export function TextArea({ className = '', ...rest }: ComponentProps<'textarea'>) {
  return <textarea className={`${inputClass} py-2.5 leading-6 ${className}`} {...rest} />;
}

/** An inline message. Errors use the warning surface and an icon, so color is not the only signal. */
export function Notice({ tone = 'info', children, action }: { tone?: 'info' | 'error' | 'success'; children: ReactNode; action?: ReactNode }) {
  const Icon = tone === 'error' ? AlertCircle : tone === 'success' ? CheckCircle2 : Info;
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} className={`flex items-start gap-3 rounded-md px-3.5 py-3 text-callout text-text ${tone === 'error' ? 'bg-warning-surface' : 'bg-surface-2'}`}>
      <Icon className={`mt-0.5 h-[18px] w-[18px] shrink-0 ${tone === 'error' ? 'text-warning' : tone === 'success' ? 'text-accent-text' : 'text-text-secondary'}`} aria-hidden="true" />
      <div className="min-w-0 flex-1">{children}</div>
      {action && <div className="-my-1.5 shrink-0">{action}</div>}
    </div>
  );
}

/** A small segmented control, for two to four mutually exclusive choices. */
export function Segmented<T extends string>({ label, value, options, onChange, block = false }: {
  label: string;
  value: T;
  options: { value: T; label: string; disabled?: boolean }[];
  onChange: (value: T) => void;
  /** Span the column, as the Summary and Transcript tabs do. */
  block?: boolean;
}) {
  return (
    <div role="radiogroup" aria-label={label} className={`${block ? 'grid w-full' : 'inline-grid'} auto-cols-fr grid-flow-col rounded-md bg-surface-2 p-0.5`}>
      {options.map((option) => {
        const selected = option.value === value;
        return (
          <button
            key={option.value}
            type="button"
            role="radio"
            aria-checked={selected}
            disabled={option.disabled}
            onClick={() => onChange(option.value)}
            className={`min-h-11 rounded-sm px-3 text-meta font-semibold transition-colors disabled:opacity-40 ${selected ? 'bg-surface text-text shadow-raised' : 'text-text-secondary hover:text-text'}`}
          >
            {option.label}
          </button>
        );
      })}
    </div>
  );
}

/** An on/off switch with a visible label. */
export function Switch({ checked, onChange, label, description, disabled }: { checked: boolean; onChange: (value: boolean) => void; label: string; description?: ReactNode; disabled?: boolean }) {
  return (
    <label className={`flex min-h-11 cursor-pointer items-start justify-between gap-4 ${disabled ? 'cursor-not-allowed opacity-60' : ''}`}>
      <span className="min-w-0">
        <span className="block text-body font-medium">{label}</span>
        {description && <span className="mt-0.5 block text-callout text-text-secondary">{description}</span>}
      </span>
      <span className="relative mt-0.5 inline-flex shrink-0">
        <input type="checkbox" role="switch" className="peer sr-only" checked={checked} disabled={disabled} onChange={(event) => onChange(event.target.checked)} />
        <span aria-hidden="true" className="h-[31px] w-[51px] rounded-full bg-separator transition-colors duration-200 peer-checked:bg-accent-fill peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent-text" />
        <span aria-hidden="true" className="absolute left-0.5 top-0.5 h-[27px] w-[27px] rounded-full bg-on-accent shadow-raised transition-transform duration-200 ease-out peer-checked:translate-x-5" />
      </span>
    </label>
  );
}
