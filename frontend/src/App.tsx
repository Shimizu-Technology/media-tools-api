import { useEffect, useState } from 'react'
import { ClerkProvider, useAuth } from '@clerk/clerk-react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { Header } from './components/Header'
import { HomePage } from './pages/HomePage'
import { MyLibraryPage } from './pages/MyLibraryPage'
import { AudioPage } from './pages/AudioPage'
import { PdfPage } from './pages/PdfPage'
import { DocsPage } from './pages/DocsPage'
import { WebhooksPage } from './pages/WebhooksPage'
import { OpsPage } from './pages/OpsPage'
import { CollectionsPage } from './pages/CollectionsPage'
import { PrivacyPage } from './pages/PrivacyPage'
import { AuthProvider } from './contexts/AuthContext'
import { setAuthTokenGetter } from './lib/apiAuth'
import { ClerkTokenSync } from './components/ClerkTokenSync'

const CLERK_PUBLISHABLE_KEY = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
const isClerkEnabled = Boolean(CLERK_PUBLISHABLE_KEY && CLERK_PUBLISHABLE_KEY !== 'YOUR_PUBLISHABLE_KEY')

// Log warning if Clerk is not configured (per Brain Dump guide)
if (!isClerkEnabled) {
  console.warn('⚠️ Clerk not configured — running without authentication. Add VITE_CLERK_PUBLISHABLE_KEY to .env.local')
}

/** Routes shared between Clerk and non-Clerk modes. */
function AppRoutes() {
  return (
    <Routes>
      <Route path="/" element={<HomePage />} />
      <Route path="/library" element={<MyLibraryPage />} />
      <Route path="/audio" element={<AudioPage />} />
      <Route path="/pdf" element={<PdfPage />} />
      <Route path="/docs" element={<DocsPage />} />
      <Route path="/webhooks" element={<WebhooksPage />} />
      <Route path="/collections" element={<CollectionsPage />} />
      <Route path="/collections/:collectionId" element={<CollectionsPage />} />
      <Route path="/ops" element={<OpsPage />} />
      <Route path="/privacy" element={<PrivacyPage />} />
      <Route path="/history" element={<Navigate to="/library?type=youtube" replace />} />
    </Routes>
  )
}

/** Footer shared between modes. */
function AppFooter() {
  return (
    <footer className="py-8 text-center text-sm" style={{ color: 'var(--color-text-muted)' }}>
      Built with Go + React by{' '}
      <a href="https://github.com/Shimizu-Technology" target="_blank" rel="noopener noreferrer"
        style={{ color: 'var(--color-brand-500)' }}>
        Shimizu Technology
      </a>
    </footer>
  )
}

/**
 * ClerkAppContent — rendered inside ClerkProvider.
 * Uses Clerk hooks safely since ClerkProvider is an ancestor.
 * Wires up token getter for authenticated API calls.
 */
function ClerkAppContent() {
  const { getToken, isLoaded, isSignedIn } = useAuth()

  useEffect(() => {
    // Wire Clerk's getToken into the API auth system
    // getToken() automatically handles token refresh (Brain Dump guide pattern)
    setAuthTokenGetter(async () => {
      try {
        return await getToken()
      } catch {
        return null
      }
    })
  }, [getToken])

  return (
    <AuthProvider
      isClerkEnabled={true}
      isAuthenticated={isSignedIn ?? false}
      isLoading={!isLoaded}
    >
      <ClerkTokenSync>
        <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)' }}>
          <Header />
          <AppRoutes />
          <AppFooter />
        </div>
      </ClerkTokenSync>
    </AuthProvider>
  )
}

/**
 * NoClerkAppContent — rendered when Clerk is not configured.
 * No auth gates — full access for development / API-key mode.
 */
function NoClerkAppContent() {
  const [hasApiKey, setHasApiKey] = useState(!!localStorage.getItem('mta_api_key'))

  // Listen for storage changes (e.g., API key set in another component)
  useEffect(() => {
    const check = () => setHasApiKey(!!localStorage.getItem('mta_api_key'))
    window.addEventListener('storage', check)
    // Also poll briefly in case same-tab writes don't fire 'storage'
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
    >
      <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)' }}>
        <Header />
        <AppRoutes />
        <AppFooter />
      </div>
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
    <ClerkProvider publishableKey={CLERK_PUBLISHABLE_KEY} afterSignOutUrl="/">
      <BrowserRouter>
        <ClerkAppContent />
      </BrowserRouter>
    </ClerkProvider>
  )
}

export default App
