import { useCallback, useEffect, useState } from 'react'
import { ClerkProvider, useAuth } from '@clerk/clerk-react'
import { BrowserRouter, Link, Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom'
import { FileText } from 'lucide-react'
import { AppShell } from './components/AppShell'
import { ProtectedRoute } from './components/ProtectedRoute'
import { HomePage } from './pages/HomePage'
import { MyLibraryPage } from './pages/MyLibraryPage'
import { AudioPage } from './pages/AudioPage'
import { PdfPage } from './pages/PdfPage'
import { DocsPage } from './pages/DocsPage'
import { WebhooksPage } from './pages/WebhooksPage'
import { OpsPage } from './pages/OpsPage'
import { CollectionsPage } from './pages/CollectionsPage'
import { PrivacyPage } from './pages/PrivacyPage'
import { LandingPage } from './pages/LandingPage'
import { DashboardPage } from './pages/DashboardPage'
import { DeveloperPage } from './pages/DeveloperPage'
import { SettingsPage } from './pages/SettingsPage'
import { AuthProvider } from './contexts/AuthContext'
import { getCurrentUser, type User } from './lib/api'
import { setAuthTokenGetter } from './lib/apiAuth'

const CLERK_PUBLISHABLE_KEY = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
const isClerkEnabled = Boolean(CLERK_PUBLISHABLE_KEY && CLERK_PUBLISHABLE_KEY !== 'YOUR_PUBLISHABLE_KEY')

if (!isClerkEnabled) {
  console.warn('Clerk not configured — using local API-key development mode. Add VITE_CLERK_PUBLISHABLE_KEY to .env.local for browser auth.')
}

function AppRoutes() {
  return (
    <Routes>
      <Route path="/" element={<LandingPage />} />

      <Route element={<PublicLayout />}>
        <Route path="/docs" element={<DocsPage />} />
        <Route path="/privacy" element={<PrivacyPage />} />
      </Route>

      <Route path="/audio" element={<LegacyRedirect to="/app/audio" />} />
      <Route path="/pdf" element={<LegacyRedirect to="/app/pdf" />} />
      <Route path="/library" element={<LegacyRedirect to="/app/library" />} />
      <Route path="/collections" element={<LegacyRedirect to="/app/collections" />} />
      <Route path="/collections/:collectionId" element={<LegacyRedirect to="/app/collections" includePathTail />} />
      <Route path="/history" element={<LegacyRedirect to="/app/library?type=youtube" />} />
      <Route path="/webhooks" element={<LegacyRedirect to="/app/developer/webhooks" />} />
      <Route path="/ops" element={<LegacyRedirect to="/app/admin/ops" />} />

      <Route
        path="/app"
        element={
          <ProtectedRoute>
            <AppShell />
          </ProtectedRoute>
        }
      >
        <Route index element={<DashboardPage />} />
        <Route path="video" element={<HomePage />} />
        <Route path="audio" element={<AudioPage />} />
        <Route path="pdf" element={<PdfPage />} />
        <Route path="library" element={<MyLibraryPage />} />
        <Route path="collections" element={<CollectionsPage />} />
        <Route path="collections/:collectionId" element={<CollectionsPage />} />
        <Route path="developer" element={<DeveloperPage />} />
        <Route path="developer/webhooks" element={<WebhooksPage />} />
		<Route path="admin/ops" element={<ProtectedRoute requireOwner><OpsPage /></ProtectedRoute>} />
        <Route path="settings" element={<SettingsPage />} />
      </Route>

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}

function LegacyRedirect({ to, includePathTail = false }: { to: string; includePathTail?: boolean }) {
  const location = useLocation()
  const [targetPath, targetSearch = ''] = to.split('?')
  const tail = includePathTail ? location.pathname.replace(/^\/collections/, '') : ''
  const search = mergeSearch(targetSearch, location.search)
  return <Navigate to={`${targetPath}${tail}${search}`} replace />
}

function mergeSearch(baseSearch: string, currentSearch: string) {
  const params = new URLSearchParams(baseSearch)
  const current = new URLSearchParams(currentSearch)
  current.forEach((value, key) => {
    if (!params.has(key)) params.set(key, value)
  })
  const serialized = params.toString()
  return serialized ? `?${serialized}` : ''
}

function PublicLayout() {
  return (
    <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)' }}>
      <header className="sticky top-0 z-50 border-b backdrop-blur" style={{ backgroundColor: 'rgba(11, 13, 16, 0.86)', borderColor: 'var(--color-border)' }}>
        <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4">
          <Link to="/" className="flex items-center gap-3">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg" style={{ backgroundColor: 'var(--color-brand-500)' }}>
              <FileText className="h-5 w-5 text-white" />
            </div>
            <div>
              <div className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>Media Tools</div>
              <div className="text-xs" style={{ color: 'var(--color-text-muted)' }}>AI media workspace</div>
            </div>
          </Link>
          <nav className="flex items-center gap-2">
            <Link to="/docs" className="min-h-11 rounded-xl px-4 py-3 text-sm font-semibold transition hover:bg-white/[0.06]" style={{ color: 'var(--color-text-secondary)' }}>API docs</Link>
            <Link to="/app" className="min-h-11 rounded-xl px-4 py-3 text-sm font-semibold text-white transition hover:opacity-90" style={{ backgroundColor: 'var(--color-brand-500)' }}>Open app</Link>
          </nav>
        </div>
      </header>
      <Outlet />
      <AppFooter />
    </div>
  )
}

function AppFooter() {
  return (
    <footer className="py-8 text-center text-sm" style={{ color: 'var(--color-text-muted)' }}>
      Built with Go + React by{' '}
      <a href="https://github.com/Shimizu-Technology" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--color-brand-500)' }}>
        Shimizu Technology
      </a>
    </footer>
  )
}

function ClerkAppContent() {
  const { getToken, isLoaded, isSignedIn } = useAuth()
  const [user, setUser] = useState<User | null>(null)
  const [isUserLoading, setIsUserLoading] = useState(false)

  useEffect(() => {
    setAuthTokenGetter(async () => {
      try {
        return await getToken()
      } catch {
        return null
      }
    })
  }, [getToken])

  const refreshUser = useCallback(async () => {
    if (!isSignedIn) {
      setUser(null)
      return
    }
    setIsUserLoading(true)
    try {
      setUser(await getCurrentUser())
    } catch {
      setUser(null)
    } finally {
      setIsUserLoading(false)
    }
  }, [isSignedIn])

  useEffect(() => {
    if (isLoaded && !isSignedIn) {
      localStorage.removeItem('mta_jwt_token')
      setUser(null)
    }
    if (isLoaded && isSignedIn) {
      void refreshUser()
    }
  }, [isLoaded, isSignedIn, refreshUser])

  return (
    <AuthProvider
      isClerkEnabled={true}
      isAuthenticated={isSignedIn ?? false}
      isLoading={!isLoaded || isUserLoading}
      canUseWorkspace={true}
      user={user}
      refreshUser={refreshUser}
    >
      <AppRoutes />
    </AuthProvider>
  )
}

function NoClerkAppContent() {
  const [hasApiKey, setHasApiKey] = useState(!!localStorage.getItem('mta_api_key'))

  useEffect(() => {
    const check = () => setHasApiKey(!!localStorage.getItem('mta_api_key'))
    window.addEventListener('storage', check)
    const interval = setInterval(check, 2000)
    return () => {
      window.removeEventListener('storage', check)
      clearInterval(interval)
    }
  }, [])

  return (
    <AuthProvider
      isClerkEnabled={false}
      isAuthenticated={hasApiKey}
      isLoading={false}
      canUseWorkspace={false}
      user={null}
      refreshUser={async () => undefined}
    >
      <AppRoutes />
    </AuthProvider>
  )
}

function App() {
  if (!isClerkEnabled) {
    return (
      <BrowserRouter>
        <NoClerkAppContent />
      </BrowserRouter>
    )
  }

  return (
    <ClerkProvider publishableKey={CLERK_PUBLISHABLE_KEY} afterSignOutUrl="/" signInFallbackRedirectUrl="/app" signUpFallbackRedirectUrl="/app">
      <BrowserRouter>
        <ClerkAppContent />
      </BrowserRouter>
    </ClerkProvider>
  )
}

export default App
