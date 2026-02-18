import { LogIn } from 'lucide-react';

const CLERK_CONFIGURED = !!import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;

/**
 * User dropdown menu — delegates to Clerk when configured.
 * NOTE: Currently unused — Header uses ClerkUserButton directly.
 * Kept for potential future use.
 */
export function UserDropdown() {
  if (!CLERK_CONFIGURED) {
    return (
      <button
        className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium transition-colors"
        style={{ color: 'var(--color-text-secondary)' }}
      >
        <LogIn className="w-4 h-4" />
        <span className="hidden sm:inline">Sign In</span>
      </button>
    );
  }

  // When Clerk is configured, use ClerkUserButton instead
  return null;
}
