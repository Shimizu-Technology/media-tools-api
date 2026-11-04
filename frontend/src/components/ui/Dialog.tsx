import { useEffect, useId, useRef, type ReactNode } from 'react';
import { X } from 'lucide-react';
import { IconButton } from './Button';

/**
 * A native modal <dialog>: the browser supplies the top layer, focus trap,
 * Escape, and inert background. On phones it sits at the bottom like a sheet;
 * from 640px it is centered. Motion lives in index.css (.sheet).
 */
export function Dialog({ open, onClose, title, children, footer, size = 'md', labelledBy }: {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: ReactNode;
  footer?: ReactNode;
  size?: 'md' | 'lg';
  labelledBy?: string;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) {
      dialog.showModal();
      // showModal focuses the first control (Close); a field marked
      // data-autofocus is where typing should start instead.
      dialog.querySelector<HTMLElement>('[data-autofocus]')?.focus();
    }
    if (!open && dialog.open) dialog.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      aria-labelledby={labelledBy ?? (title ? titleId : undefined)}
      onCancel={(event) => { event.preventDefault(); onClose(); }}
      onClick={(event) => { if (event.target === event.currentTarget) onClose(); }}
      className={`sheet ${size === 'lg' ? 'sm:max-w-2xl' : 'sm:max-w-md'}`}
    >
      {open && (
        <div className="flex max-h-[inherit] flex-col">
          {title && (
            <div className="flex items-center gap-2 px-5 pb-1 pt-4">
              <h2 id={titleId} className="min-w-0 flex-1 text-heading">{title}</h2>
              <IconButton label="Close" tone="neutral" onClick={onClose} className="-mr-2"><X className="h-5 w-5" /></IconButton>
            </div>
          )}
          <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 pb-5 pt-2">{children}</div>
          {footer && <div className="border-t border-separator px-5 pb-[max(1rem,env(safe-area-inset-bottom))] pt-3">{footer}</div>}
        </div>
      )}
    </dialog>
  );
}
