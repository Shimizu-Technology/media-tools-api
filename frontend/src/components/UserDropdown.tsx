import { SignedIn, SignedOut, SignInButton, UserButton } from '@clerk/clerk-react';
import { LogIn } from 'lucide-react';

/**
 * User dropdown menu — uses Clerk components for auth (MTA-20 → Clerk migration).
 * Falls back to a basic sign-in button if user is not authenticated.
 */
export function UserDropdown() {
  return (
    <>
      <SignedIn>
        <UserButton
          appearance={{
            elements: {
              avatarBox: 'w-8 h-8',
            },
          }}
        />
      </SignedIn>
      <SignedOut>
        <SignInButton mode="modal">
          <button
            className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium transition-colors"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            <LogIn className="w-4 h-4" />
            <span className="hidden sm:inline">Sign In</span>
          </button>
        </SignInButton>
      </SignedOut>
    </>
  );
}
