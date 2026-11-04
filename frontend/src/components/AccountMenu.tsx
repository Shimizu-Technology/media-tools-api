import { useState } from 'react';
import { LogOut, Settings } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';
import { Menu } from './ui/Menu';

export function AccountMenu() {
  const { user, signOut } = useAuthContext();
  const navigate = useNavigate();
  const [error, setError] = useState(false);
  const initials = (user?.name || user?.email || 'MT').split(/\s+/).map((part) => part[0]).join('').slice(0, 2).toUpperCase();

  const handleSignOut = async () => {
    setError(false);
    try { await signOut(); } catch { setError(true); }
  };

  return (
    <div className="relative">
      <Menu
        label={`Account: ${user?.email ?? 'signed in'}`}
        align="start"
        side="top"
        triggerClassName="pressable flex min-h-11 w-full items-center gap-2.5 rounded-md px-2 py-1 text-left hover:bg-fill"
        trigger={<>
          <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-accent-fill text-meta font-bold text-on-accent">{initials}</span>
          <span className="min-w-0 flex-1 truncate text-meta font-medium text-text-secondary">{user?.email ?? 'Your account'}</span>
        </>}
        items={[
          { label: 'Settings', icon: <Settings />, onSelect: () => navigate('/app/settings') },
          { label: 'Sign out', icon: <LogOut />, onSelect: () => void handleSignOut() },
        ]}
      />
      {error && <p role="alert" className="absolute bottom-full left-0 mb-1 w-48 rounded-md bg-surface p-2 text-meta shadow-overlay">Could not sign out. Try again.</p>}
    </div>
  );
}
