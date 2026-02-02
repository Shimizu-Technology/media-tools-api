import { motion } from 'framer-motion';
import { useLocation, Link } from 'react-router-dom';
import { Sun, Moon, FileText, Github, History, Book, Mic, FileType2, Webhook } from 'lucide-react';
import { UserDropdown } from './UserDropdown';

interface HeaderProps {
  isDark: boolean;
  onToggleTheme: () => void;
}

/**
 * App header with branding, navigation, theme toggle, user menu, and GitHub link.
 * NO emoji — using Lucide React icons only (Shimizu design guide).
 */
export function Header({ isDark, onToggleTheme }: HeaderProps) {
  const location = useLocation();

  const navLinks = [
    { to: '/', label: 'Extract', icon: FileText },
    { to: '/audio', label: 'Audio', icon: Mic },
    { to: '/pdf', label: 'PDF', icon: FileType2 },
    { to: '/history', label: 'History', icon: History },
    { to: '/webhooks', label: 'Webhooks', icon: Webhook },
    { to: '/docs', label: 'API Docs', icon: Book },
  ];

  return (
    <motion.header
      initial={{ opacity: 0, y: -20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
      className="fixed top-0 left-0 right-0 z-50 border-b"
      style={{
        backgroundColor: 'var(--color-surface)',
        borderColor: 'var(--color-border)',
      }}
    >
      <div className="max-w-5xl mx-auto px-6 h-16 flex items-center justify-between">
        {/* Logo + Brand */}
        <Link to="/" className="flex items-center gap-3">
          <div
            className="w-9 h-9 rounded-xl flex items-center justify-center"
            style={{ backgroundColor: 'var(--color-brand-500)' }}
          >
            <FileText className="w-5 h-5 text-white" />
          </div>
          <div className="hidden sm:block">
            <h1 className="text-base font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>
              Media Tools
            </h1>
            <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
              YouTube Transcripts & AI Summaries
            </p>
          </div>
        </Link>

        {/* Navigation */}
        <nav className="flex items-center gap-1">
          {navLinks.map((link) => {
            const isActive = location.pathname === link.to;
            return (
              <Link
                key={link.to}
                to={link.to}
                className="relative flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium transition-colors duration-200"
                style={{
                  color: isActive ? 'var(--color-brand-500)' : 'var(--color-text-secondary)',
                  minHeight: '40px',
                }}
              >
                <link.icon className="w-4 h-4" />
                <span className="hidden sm:inline">{link.label}</span>
              </Link>
            );
          })}
        </nav>

        {/* Actions */}
        <div className="flex items-center gap-2">
          <UserDropdown />
          <a
            href="https://github.com/Shimizu-Technology/media-tools-api"
            target="_blank"
            rel="noopener noreferrer"
            className="p-2.5 rounded-lg transition-colors duration-200 hover:opacity-80"
            style={{ color: 'var(--color-text-secondary)' }}
            aria-label="View on GitHub"
          >
            <Github className="w-5 h-5" />
          </a>
          <button
            onClick={onToggleTheme}
            className="p-2.5 rounded-lg transition-colors duration-200 hover:opacity-80"
            style={{ color: 'var(--color-text-secondary)' }}
            aria-label={isDark ? 'Switch to light mode' : 'Switch to dark mode'}
          >
            {isDark ? <Sun className="w-5 h-5" /> : <Moon className="w-5 h-5" />}
          </button>
        </div>
      </div>
    </motion.header>
  );
}
