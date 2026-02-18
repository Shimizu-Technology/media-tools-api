/**
 * Clerk UserButton wrapper — only import this inside ClerkProvider.
 * Separated so Clerk hooks are never called without ClerkProvider ancestor.
 */
import { SignedIn, UserButton } from '@clerk/clerk-react';

export function ClerkUserButton() {
  return (
    <SignedIn>
      <UserButton
        appearance={{
          elements: {
            avatarBox: 'w-8 h-8',
          },
        }}
      />
    </SignedIn>
  );
}
