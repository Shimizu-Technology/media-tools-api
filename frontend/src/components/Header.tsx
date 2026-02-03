import { Link, useLocation } from 'react-router-dom'
import { FileText, Mic, FileType2, History, Webhook, Book, LogIn, Github } from 'lucide-react'

const navLinks = [
  { to: '/', label: 'Extract', icon: FileText },
  { to: '/audio', label: 'Audio', icon: Mic },
  { to: '/pdf', label: 'PDF', icon: FileType2 },
  { to: '/history', label: 'History', icon: History },
  { to: '/webhooks', label: 'Webhooks', icon: Webhook },
  { to: '/docs', label: 'API Docs', icon: Book },
]

export function Header() {
  const location = useLocation()

  return (
    <header
      className="sticky top-0 z-50 border-b"
      style={{
        backgroundColor: 'var(--color-surface)',
        borderColor: 'var(--color-border)',
      }}
    >
      <div className="max-w-6xl mx-auto px-4 h-16 flex items-center justify-between">
        {/* Logo */}
        <Link to="/" className="flex items-center gap-3">
          <div
            className="w-9 h-9 rounded-lg flex items-center justify-center"
            style={{ backgroundColor: 'var(--color-brand-500)' }}
          >
            <FileText className="w-5 h-5 text-white" />
          </div>
          <div className="hidden sm:block">
            <div className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>
              Media Tools
            </div>
            <div className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
              YouTube Transcripts & AI Summaries
            </div>
          </div>
        </Link>

        {/* Navigation */}
        <nav className="flex items-center gap-1">
          {navLinks.map((link) => {
            const isActive = location.pathname === link.to
            const Icon = link.icon
            return (
              <Link
                key={link.to}
                to={link.to}
                className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium transition-colors"
                style={{
                  color: isActive ? 'var(--color-brand-500)' : 'var(--color-text-secondary)',
                }}
              >
                <Icon className="w-4 h-4" />
                <span className="hidden md:inline">{link.label}</span>
              </Link>
            )
          })}
        </nav>

        {/* Actions */}
        <div className="flex items-center gap-2">
          <Link
            to="/auth"
            className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm font-medium"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            <LogIn className="w-4 h-4" />
            <span className="hidden sm:inline">Sign In</span>
          </Link>
          <a
            href="https://github.com/Shimizu-Technology/media-tools-api"
            target="_blank"
            rel="noopener noreferrer"
            className="p-2 rounded-lg"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            <Github className="w-5 h-5" />
          </a>
        </div>
      </div>
    </header>
  )
}
