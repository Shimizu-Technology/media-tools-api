/**
 * Clerk UserButton wrapper — only import this inside ClerkProvider.
 * Separated so Clerk hooks are never called without ClerkProvider ancestor.
 */
import { SignInButton, SignedIn, SignedOut, UserButton } from '@clerk/clerk-react';
import { LogIn } from 'lucide-react';

export function ClerkUserButton() {
  return (
    <>
      <SignedOut>
        <SignInButton mode="modal">
          <button
            className="inline-flex items-center justify-center gap-1.5 px-3 py-2.5 rounded-lg text-sm font-medium transition-colors hover:opacity-80"
            style={{
              color: 'var(--color-text-primary)',
              backgroundColor: 'var(--color-surface-overlay)',
              minWidth: '44px',
              minHeight: '44px',
            }}
          >
            <LogIn className="w-4 h-4" />
            <span className="hidden sm:inline">Sign in</span>
          </button>
        </SignInButton>
      </SignedOut>
      <SignedIn>
        <UserButton
          appearance={{
            elements: {
              avatarBox: 'w-8 h-8',
            },
          }}
        />
      </SignedIn>
    </>
  );
}
