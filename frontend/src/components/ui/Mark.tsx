/**
 * The Media Tools mark: a page with an opening quotation, in ink. Same drawing
 * as public/icon.svg and the iOS app icon.
 */
export function Mark({ size = 32, className = '' }: { size?: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 1024 1024" aria-hidden="true" focusable="false" className={`shrink-0 ${className}`}>
      <rect width="1024" height="1024" rx="229" fill="#1F4F9E" />
      <rect x="128" y="128" width="768" height="768" rx="112" fill="#F7F5F0" />
      <circle cx="386" cy="590" r="96" fill="#1F4F9E" />
      <path d="M290 590C290 479.6 371.6 393.2 445.52 374L462.8 405.68C410 434.48 387.92 489.2 397.52 537.2Z" fill="#1F4F9E" />
      <circle cx="640" cy="590" r="96" fill="#1F4F9E" />
      <path d="M544 590C544 479.6 625.6 393.2 699.52 374L716.8 405.68C664 434.48 641.92 489.2 651.52 537.2Z" fill="#1F4F9E" />
    </svg>
  );
}

export function Wordmark({ size = 28 }: { size?: number }) {
  return (
    <span className="inline-flex items-center gap-2.5">
      <Mark size={size} />
      <span className="font-serif text-[1.0625rem] font-semibold tracking-[-0.01em]">Media Tools</span>
    </span>
  );
}
