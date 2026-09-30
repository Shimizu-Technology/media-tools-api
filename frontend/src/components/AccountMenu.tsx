import { useState } from 'react';
import { LogOut, Settings } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';

export function AccountMenu() {
  const { user, signOut } = useAuthContext();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(false);
  const initials = (user?.name || user?.email || 'MT').split(/\s+/).map((part) => part[0]).join('').slice(0, 2).toUpperCase();

  const handleSignOut = async () => {
    setPending(true);
    setError(false);
    try { await signOut(); } catch { setError(true); } finally { setPending(false); }
  };

  return (
    <details className="group relative">
      <summary className="flex h-11 w-11 cursor-pointer list-none items-center justify-center rounded-xl outline-none transition hover:bg-[var(--color-nav-hover)] focus-visible:ring-2 focus-visible:ring-[var(--color-brand-500)]" aria-label="Open account menu">
        <span className="flex h-8 w-8 items-center justify-center rounded-full text-xs font-bold" style={{ backgroundColor: 'var(--color-brand-500)', color: 'var(--color-on-brand)' }}>{initials}</span>
      </summary>
      <div className="absolute right-0 z-50 mt-2 w-56 overflow-hidden rounded-2xl border p-2 shadow-2xl" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="border-b px-3 py-2" style={{ borderColor: 'var(--color-border)' }}><p className="truncate text-sm font-semibold">{user?.name || 'Media Tools account'}</p><p className="truncate text-xs" style={{ color: 'var(--color-text-muted)' }}>{user?.email}</p></div>
        <Link to="/app/settings" className="mt-1 flex min-h-11 items-center gap-3 rounded-xl px-3 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)]"><Settings className="h-4 w-4" />Account settings</Link>
        <button type="button" onClick={() => void handleSignOut()} disabled={pending} className="flex min-h-11 w-full items-center gap-3 rounded-xl px-3 text-left text-sm font-semibold transition hover:bg-[var(--color-nav-hover)] disabled:opacity-60" style={{ color: 'var(--color-text-secondary)' }}><LogOut className="h-4 w-4" />{pending ? 'Signing out…' : 'Sign out'}</button>
        {error && <p role="alert" className="px-3 py-2 text-xs" style={{ color: 'var(--color-error)' }}>Could not sign out. Please try again.</p>}
      </div>
    </details>
  );
}
