import { useState, useRef, useEffect } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { FileText, Mic, FileType2, Library, Settings, Book, Webhook, Key, Github, ChevronDown } from 'lucide-react'
import { ApiKeySetup } from './ApiKeySetup'

const mainNavLinks = [
  { to: '/', label: 'YouTube', icon: FileText },
  { to: '/audio', label: 'Audio', icon: Mic },
  { to: '/pdf', label: 'PDF', icon: FileType2 },
  { to: '/library', label: 'My Library', icon: Library },
]

const settingsLinks = [
  { to: '/docs', label: 'API Docs', icon: Book },
  { to: '/webhooks', label: 'Webhooks', icon: Webhook },
]

export function Header() {
  const location = useLocation()
  const [showSettings, setShowSettings] = useState(false)
  const [showApiKeyModal, setShowApiKeyModal] = useState(false)
  const settingsRef = useRef<HTMLDivElement>(null)
  const [hasApiKey, setHasApiKey] = useState(() => !!localStorage.getItem('mta_api_key'))

  // Close dropdown when clicking outside
  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (settingsRef.current && !settingsRef.current.contains(event.target as Node)) {
        setShowSettings(false)
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  // Close dropdown on route change
  useEffect(() => {
    setShowSettings(false)
  }, [location.pathname])

  const handleApiKeySet = (key: string) => {
    setHasApiKey(!!key)
    setShowApiKeyModal(false)
  }

  return (
    <>
      <header
        className="sticky top-0 z-50 border-b backdrop-blur"
        style={{
          backgroundColor: 'rgba(11, 13, 16, 0.86)',
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

          {/* Main Navigation */}
          <nav className="flex items-center gap-0.5 sm:gap-1">
            {mainNavLinks.map((link) => {
              const isActive = link.to === '/' 
                ? location.pathname === '/'
                : location.pathname.startsWith(link.to)
              const Icon = link.icon
              return (
                <Link
                  key={link.to}
                  to={link.to}
                  className="flex items-center justify-center gap-1.5 px-2 sm:px-3 py-2.5 rounded-lg text-sm font-medium transition-colors hover:opacity-80"
                  style={{
                    color: isActive ? 'var(--color-brand-500)' : 'var(--color-text-secondary)',
                    backgroundColor: isActive ? 'var(--color-brand-50)' : 'transparent',
                    minWidth: '44px',
                    minHeight: '44px',
                  }}
                  title={link.label}
                >
                  <Icon className="w-4 h-4" />
                  <span className="hidden md:inline">{link.label}</span>
                </Link>
              )
            })}
          </nav>

          {/* Actions */}
          <div className="flex items-center gap-1">
            {/* Settings Dropdown */}
            <div className="relative" ref={settingsRef}>
              <button
                onClick={() => setShowSettings(!showSettings)}
                className="flex items-center justify-center gap-1 px-2 sm:px-3 py-2.5 rounded-lg text-sm font-medium transition-colors hover:opacity-80"
                style={{
                  color: showSettings ? 'var(--color-brand-500)' : 'var(--color-text-secondary)',
                  backgroundColor: showSettings ? 'var(--color-brand-50)' : 'transparent',
                  minWidth: '44px',
                  minHeight: '44px',
                }}
                title="Settings & Developer"
              >
                <Settings className="w-4 h-4" />
                <ChevronDown className="w-3 h-3 hidden sm:block" />
              </button>

              {showSettings && (
                <div
                  className="absolute right-0 mt-2 w-56 rounded-xl border shadow-lg overflow-hidden z-50"
                  style={{
                    backgroundColor: 'var(--color-surface-elevated)',
                    borderColor: 'var(--color-border)',
                  }}
                >
                  {/* API Key Status */}
                  <button
                    onClick={() => { setShowApiKeyModal(true); setShowSettings(false); }}
                    className="w-full flex items-center gap-3 px-4 py-3 text-sm transition-colors text-left hover:opacity-80"
                    style={{
                      color: 'var(--color-text-primary)',
                      backgroundColor: 'transparent',
                    }}
                  >
                    <Key className="w-4 h-4" style={{ color: hasApiKey ? 'var(--color-success)' : 'var(--color-text-muted)' }} />
                    <div className="flex-1">
                      <p className="font-medium">API Key</p>
                      <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
                        {hasApiKey ? 'Configured' : 'Not set'}
                      </p>
                    </div>
                  </button>

                  <div className="h-px" style={{ backgroundColor: 'var(--color-border)' }} />

                  {/* Settings Links */}
                  {settingsLinks.map((link) => {
                    const Icon = link.icon
                    const isActive = location.pathname === link.to
                    return (
                      <Link
                        key={link.to}
                        to={link.to}
                        className="flex items-center gap-3 px-4 py-3 text-sm transition-colors hover:opacity-80"
                        style={{
                          color: isActive ? 'var(--color-brand-500)' : 'var(--color-text-primary)',
                          backgroundColor: isActive ? 'var(--color-brand-50)' : 'transparent',
                        }}
                      >
                        <Icon className="w-4 h-4" style={{ color: 'var(--color-text-muted)' }} />
                        {link.label}
                      </Link>
                    )
                  })}

                  <div className="h-px" style={{ backgroundColor: 'var(--color-border)' }} />

                  {/* GitHub Link */}
                  <a
                    href="https://github.com/Shimizu-Technology/media-tools-api"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="flex items-center gap-3 px-4 py-3 text-sm transition-colors hover:opacity-80"
                    style={{ color: 'var(--color-text-primary)' }}
                  >
                    <Github className="w-4 h-4" style={{ color: 'var(--color-text-muted)' }} />
                    View on GitHub
                  </a>
                </div>
              )}
            </div>
          </div>
        </div>
      </header>

      {/* API Key Modal */}
      {showApiKeyModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div
            className="absolute inset-0 bg-black/50"
            onClick={() => setShowApiKeyModal(false)}
          />
          <div
            className="relative w-full max-w-md p-6 rounded-2xl border shadow-xl"
            style={{
              backgroundColor: 'var(--color-surface-elevated)',
              borderColor: 'var(--color-border)',
            }}
          >
            <h2
              className="text-lg font-semibold mb-4"
              style={{ color: 'var(--color-text-primary)' }}
            >
              API Key Settings
            </h2>
            <ApiKeySetup onKeySet={handleApiKeySet} hasKey={hasApiKey} />
            <button
              onClick={() => setShowApiKeyModal(false)}
              className="mt-4 w-full py-2.5 rounded-lg text-sm font-medium border transition-colors"
              style={{
                borderColor: 'var(--color-border)',
                color: 'var(--color-text-secondary)',
                minHeight: '44px',
              }}
            >
              Close
            </button>
          </div>
        </div>
      )}
    </>
  )
}
