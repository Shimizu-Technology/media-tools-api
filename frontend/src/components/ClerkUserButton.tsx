/**
 * Clerk account menu without Clerk's built-in self-deletion control. Account
 * deletion must pass through Media Tools so application data and raw media are
 * removed before the identity provider is called.
 */
import { SignInButton, SignedIn, SignedOut, useClerk, useUser } from '@clerk/clerk-react';
import { LogIn, LogOut, Settings } from 'lucide-react';
import { Link } from 'react-router-dom';

function SignedInAccountMenu() {
  const { signOut } = useClerk();
  const { user } = useUser();

  return (
    <details className="group relative">
      <summary className="flex h-11 w-11 cursor-pointer list-none items-center justify-center rounded-xl outline-none transition hover:bg-white/[0.06] focus-visible:ring-2 focus-visible:ring-[var(--color-brand-500)]" aria-label="Open account menu">
        {user?.imageUrl ? (
          <img src={user.imageUrl} alt="" className="h-8 w-8 rounded-full object-cover" referrerPolicy="no-referrer" />
        ) : (
          <span className="flex h-8 w-8 items-center justify-center rounded-full text-xs font-bold text-white" style={{ backgroundColor: 'var(--color-brand-500)' }}>MT</span>
        )}
      </summary>
      <div className="absolute right-0 z-50 mt-2 w-52 overflow-hidden rounded-2xl border p-2 shadow-2xl" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <Link to="/app/settings" className="flex min-h-11 items-center gap-3 rounded-xl px-3 text-sm font-semibold transition hover:bg-white/[0.06]" style={{ color: 'var(--color-text-primary)' }}>
          <Settings className="h-4 w-4" />
          Account settings
        </Link>
        <button type="button" onClick={() => void signOut({ redirectUrl: '/' })} className="flex min-h-11 w-full items-center gap-3 rounded-xl px-3 text-left text-sm font-semibold transition hover:bg-white/[0.06]" style={{ color: 'var(--color-text-secondary)' }}>
          <LogOut className="h-4 w-4" />
          Sign out
        </button>
      </div>
    </details>
  );
}

export function ClerkUserButton() {
  return (
    <>
      <SignedOut>
        <SignInButton mode="modal">
          <button className="inline-flex min-h-11 min-w-11 items-center justify-center gap-1.5 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors hover:opacity-80" style={{ color: 'var(--color-text-primary)', backgroundColor: 'var(--color-surface-overlay)' }}>
            <LogIn className="h-4 w-4" />
            <span className="hidden sm:inline">Sign in</span>
          </button>
        </SignInButton>
      </SignedOut>
      <SignedIn>
        <SignedInAccountMenu />
      </SignedIn>
    </>
  );
}
