import { useId, useState, type InputHTMLAttributes, type ReactNode } from 'react';
import { Eye, EyeOff, Loader2 } from 'lucide-react';
import { buttonClass, inputClass as baseInputClass } from '../ui/styles';

const inputClass = `${baseInputClass} mt-1.5 min-h-12`;

type FieldProps = Omit<InputHTMLAttributes<HTMLInputElement>, 'className' | 'style'> & { label: string; hint?: ReactNode };

/** A labelled input; 16px text keeps iOS Safari from zooming on focus. */
export function TextField({ label, hint, id, ...input }: FieldProps) {
  const generated = useId();
  const fieldId = id ?? generated;
  return (
    <div>
      <label htmlFor={fieldId} className="block text-callout font-semibold">{label}</label>
      <input id={fieldId} aria-describedby={hint ? `${fieldId}-hint` : undefined} className={inputClass} {...input} />
      {hint && <p id={`${fieldId}-hint`} className="mt-1.5 text-meta text-text-secondary">{hint}</p>}
    </div>
  );
}

export function EmailField(props: Omit<FieldProps, 'type' | 'label'> & { label?: string }) {
  return <TextField label="Email" type="email" inputMode="email" autoCapitalize="none" autoCorrect="off" spellCheck={false} {...props} />;
}

export function PasswordField({ label, hint, id, ...input }: Omit<FieldProps, 'type'>) {
  const generated = useId();
  const fieldId = id ?? generated;
  const [visible, setVisible] = useState(false);
  return (
    <div>
      <label htmlFor={fieldId} className="block text-callout font-semibold">{label}</label>
      <div className="relative">
        <input id={fieldId} aria-describedby={hint ? `${fieldId}-hint` : undefined} type={visible ? 'text' : 'password'} autoCapitalize="none" autoCorrect="off" spellCheck={false} className={`${inputClass} pr-12`} {...input} />
        <button type="button" onClick={() => setVisible((value) => !value)} aria-label={visible ? `Hide ${label.toLowerCase()}` : `Show ${label.toLowerCase()}`} aria-pressed={visible} className="absolute right-0.5 top-1.5 flex h-12 w-11 items-center justify-center rounded-md text-text-secondary">
          {visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
        </button>
      </div>
      {hint && <p id={`${fieldId}-hint`} className="mt-1.5 text-meta text-text-secondary">{hint}</p>}
    </div>
  );
}

/** Six digits from the email. The browser and password managers can fill it from the message. */
export function CodeField({ value, onChange, disabled }: { value: string; onChange: (value: string) => void; disabled?: boolean }) {
  return (
    <TextField
      label="6-digit code"
      value={value}
      disabled={disabled}
      onChange={(event) => onChange(event.target.value.replace(/\D/g, '').slice(0, 6))}
      inputMode="numeric"
      autoComplete="one-time-code"
      maxLength={6}
      placeholder="123456"
      hint="Codes expire after 10 minutes."
    />
  );
}

export function PrimaryButton({ busy, busyLabel, children, disabled, ...rest }: { busy?: boolean; busyLabel?: string; children: ReactNode } & Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className' | 'style'>) {
  return (
    <button disabled={busy || disabled} className={buttonClass({ variant: 'primary', block: true, className: 'min-h-12' })} {...rest}>
      {busy && <Loader2 className="h-4 w-4 animate-spin" />}{busy ? busyLabel ?? 'Working…' : children}
    </button>
  );
}

export function SecondaryButton({ children, ...rest }: { children: ReactNode } & Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className' | 'style'>) {
  return (
    <button className={buttonClass()} {...rest}>
      {children}
    </button>
  );
}
