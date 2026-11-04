import { useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { AnimatePresence, motion } from 'framer-motion';

export type MenuItem =
  | { kind?: 'item'; label: string; icon?: ReactNode; onSelect: () => void; disabled?: boolean; tone?: 'default' | 'danger' }
  | { kind: 'separator' };

/**
 * An overflow menu for rare actions. Opens from its trigger in 150ms, closes on
 * Escape, outside press, scroll, or selection, and supports arrow keys. The
 * list lives in the browser's top layer (popover API) at a fixed position, so
 * no list row, card or scroll box can clip it or paint over it.
 */
export function Menu({ label, trigger, items, align = 'end', triggerClassName = '' }: {
  label: string;
  trigger: ReactNode;
  items: MenuItem[];
  align?: 'start' | 'end';
  triggerClassName?: string;
}) {
  const [open, setOpen] = useState(false);
  const [position, setPosition] = useState<CSSProperties>({});
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const id = useId();

  useEffect(() => {
    if (!open) return;
    const onPointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        setOpen(false);
        triggerRef.current?.focus();
      }
    };
    // A fixed menu would drift from its trigger; close instead.
    const onMove = (event: Event) => {
      if (event.target instanceof Node && listRef.current?.contains(event.target)) return;
      setOpen(false);
    };
    document.addEventListener('pointerdown', onPointer);
    document.addEventListener('keydown', onKey);
    window.addEventListener('scroll', onMove, true);
    window.addEventListener('resize', onMove);
    const first = listRef.current?.querySelector<HTMLButtonElement>('[role="menuitem"]:not([disabled])');
    first?.focus();
    return () => {
      document.removeEventListener('pointerdown', onPointer);
      document.removeEventListener('keydown', onKey);
      window.removeEventListener('scroll', onMove, true);
      window.removeEventListener('resize', onMove);
    };
  }, [open]);

  // Into the top layer as soon as the list mounts.
  useLayoutEffect(() => {
    const list = listRef.current as (HTMLDivElement & { showPopover?: () => void }) | null;
    if (!open || !list?.showPopover) return;
    try { list.showPopover(); } catch { /* Already shown. */ }
  }, [open]);

  const toggle = () => {
    const rect = triggerRef.current?.getBoundingClientRect();
    if (!open && rect) {
      setPosition(align === 'end'
        ? { top: rect.bottom + 4, right: Math.max(8, window.innerWidth - rect.right), left: 'auto' }
        : { top: rect.bottom + 4, left: Math.max(8, rect.left), right: 'auto' });
    }
    setOpen((value) => !value);
  };

  const moveFocus = (direction: 1 | -1) => {
    const entries = Array.from(listRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not([disabled])') ?? []);
    if (entries.length === 0) return;
    const index = entries.indexOf(document.activeElement as HTMLButtonElement);
    entries[(index + direction + entries.length) % entries.length]?.focus();
  };

  return (
    <div ref={rootRef} className="relative">
      <button
        ref={triggerRef}
        type="button"
        aria-label={label}
        title={label}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={toggle}
        className={triggerClassName || 'pressable inline-flex h-11 w-11 items-center justify-center rounded-full text-accent hover:bg-fill'}
      >
        {trigger}
      </button>
      <AnimatePresence>
        {open && (
          <motion.div
            ref={listRef}
            id={id}
            role="menu"
            aria-label={label}
            popover="manual"
            initial={{ opacity: 0, transform: 'scale(0.97)' }}
            animate={{ opacity: 1, transform: 'scale(1)' }}
            exit={{ opacity: 0, transform: 'scale(0.97)', transition: { duration: 0.1 } }}
            transition={{ duration: 0.15, ease: [0.23, 1, 0.32, 1] }}
            style={{ ...position, position: 'fixed', bottom: 'auto', margin: 0, transformOrigin: align === 'end' ? 'top right' : 'top left' }}
            onKeyDown={(event) => {
              if (event.key === 'ArrowDown') { event.preventDefault(); moveFocus(1); }
              if (event.key === 'ArrowUp') { event.preventDefault(); moveFocus(-1); }
              if (event.key === 'Tab') setOpen(false);
            }}
            className="z-50 max-h-[min(70dvh,28rem)] min-w-56 max-w-[calc(100vw-1rem)] overflow-y-auto rounded-lg border border-separator bg-surface p-1.5 text-text shadow-overlay"
          >
            {items.map((item, index) => item.kind === 'separator'
              ? <div key={`separator-${index}`} role="separator" className="my-1 h-px bg-separator" />
              : (
                <button
                  key={`${index}-${item.label}`}
                  type="button"
                  role="menuitem"
                  disabled={item.disabled}
                  onClick={() => { setOpen(false); item.onSelect(); }}
                  className={`flex min-h-11 w-full items-center gap-3 rounded-sm px-3 text-left text-callout hover:bg-fill focus-visible:bg-fill focus-visible:outline-none disabled:opacity-40 ${item.tone === 'danger' ? 'text-danger' : 'text-text'}`}
                >
                  {item.icon && <span className="flex h-5 w-5 shrink-0 items-center justify-center text-text-secondary [&>svg]:h-[18px] [&>svg]:w-[18px]" aria-hidden="true">{item.icon}</span>}
                  <span className="min-w-0 flex-1 truncate">{item.label}</span>
                </button>
              ))}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
