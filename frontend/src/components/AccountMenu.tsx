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
        triggerClassName="pressable flex h-11 w-11 items-center justify-center rounded-full hover:bg-fill"
        trigger={<span className="flex h-8 w-8 items-center justify-center rounded-full bg-accent-fill text-meta font-bold text-on-accent">{initials}</span>}
        items={[
          { label: 'Settings', icon: <Settings />, onSelect: () => navigate('/app/settings') },
          { label: 'Sign out', icon: <LogOut />, onSelect: () => void handleSignOut() },
        ]}
      />
      {error && <p role="alert" className="absolute right-0 top-full mt-1 w-48 rounded-md bg-surface p-2 text-meta shadow-overlay">Could not sign out. Try again.</p>}
    </div>
  );
}
