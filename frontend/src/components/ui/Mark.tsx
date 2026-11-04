import { useId } from 'react';

/**
 * The Media Tools mark: white sound bars rising over a horizon, on the amber to
 * coral to red gradient. Same drawing as public/icon.svg and the iOS app icon.
 */
export function Mark({ size = 32, className = '' }: { size?: number; className?: string }) {
  const id = useId().replace(/[^a-zA-Z0-9]/g, '');
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" aria-hidden="true" focusable="false" className={`shrink-0 ${className}`}>
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#F59A3C" />
          <stop offset=".55" stopColor="#DC4F22" />
          <stop offset="1" stopColor="#AE2733" />
        </linearGradient>
      </defs>
      <rect width="100" height="100" rx="22.5" fill={`url(#${id})`} />
      <g fill="none" stroke="#fff" strokeLinecap="round">
        <path strokeWidth="7.5" d="M22 66v-8M36 66V44M50 66V30M64 66V44M78 66v-8" />
        <path strokeWidth="6" d="M14 78h72" />
      </g>
    </svg>
  );
}

export function Wordmark({ size = 28 }: { size?: number }) {
  return (
    <span className="inline-flex items-center gap-2.5">
      <Mark size={size} />
      <span className="font-display text-[1.0625rem] font-extrabold tracking-[-0.01em]">Media Tools</span>
    </span>
  );
}
