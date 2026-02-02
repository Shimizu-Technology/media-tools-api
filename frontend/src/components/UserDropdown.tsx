import { useState, useRef, useEffect } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import { User, LogOut, Layout, LogIn } from 'lucide-react';
import { useAuthStore } from '../stores/authStore';

/**
 * User dropdown menu — shows login button or user menu (MTA-20).
 */
export function UserDropdown() {
  const { user, isAuthenticated, logout } = useAuthStore();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();

  // Close on click outside
  useEffect(() => {
    const handleClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, []);

  if (!isAuthenticated) {
    return (
      <Link
        to="/auth"
        className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium transition-colors"
        style={{ color: 'var(--color-text-secondary)' }}
      >
        <LogIn className="w-4 h-4" />
        <span className="hidden sm:inline">Sign In</span>
      </Link>
    );
  }

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen(!open)}
        className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium transition-colors"
        style={{ color: 'var(--color-text-secondary)' }}
      >
        <div
          className="w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold text-white"
          style={{ backgroundColor: 'var(--color-brand-500)' }}
        >
          {user?.name?.charAt(0).toUpperCase() || 'U'}
        </div>
        <span className="hidden sm:inline max-w-[100px] truncate">{user?.name}</span>
      </button>

      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ opacity: 0, y: -5, scale: 0.95 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -5, scale: 0.95 }}
            transition={{ duration: 0.15 }}
            className="absolute right-0 top-full mt-2 w-56 rounded-xl border shadow-lg overflow-hidden z-50"
            style={{
              backgroundColor: 'var(--color-surface-overlay)',
              borderColor: 'var(--color-border)',
            }}
          >
            <div className="p-3 border-b" style={{ borderColor: 'var(--color-border)' }}>
              <p className="text-sm font-medium truncate" style={{ color: 'var(--color-text-primary)' }}>
                {user?.name}
              </p>
              <p className="text-xs truncate" style={{ color: 'var(--color-text-muted)' }}>
                {user?.email}
              </p>
            </div>
            <div className="py-1">
              <button
                onClick={() => { navigate('/workspace'); setOpen(false); }}
                className="w-full flex items-center gap-2 px-3 py-2 text-sm transition-colors hover:opacity-80"
                style={{ color: 'var(--color-text-secondary)' }}
              >
                <Layout className="w-4 h-4" />
                Workspace
              </button>
              <button
                onClick={() => { navigate('/auth'); setOpen(false); }}
                className="w-full flex items-center gap-2 px-3 py-2 text-sm transition-colors hover:opacity-80"
                style={{ color: 'var(--color-text-secondary)' }}
              >
                <User className="w-4 h-4" />
                Account
              </button>
              <button
                onClick={() => { logout(); setOpen(false); navigate('/'); }}
                className="w-full flex items-center gap-2 px-3 py-2 text-sm text-red-500 transition-colors hover:opacity-80"
              >
                <LogOut className="w-4 h-4" />
                Sign Out
              </button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
