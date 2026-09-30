import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from 'react'
import { ClerkProvider, useAuth, useClerk } from '@clerk/clerk-react'
import { BrowserRouter, Link, Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom'
import { FileText } from 'lucide-react'
import { AppShell } from './components/AppShell'
import { ProtectedRoute } from './components/ProtectedRoute'
import { ScrollToTop } from './components/ScrollToTop'
import { AuthProvider } from './contexts/AuthContext'
import { AIProcessingConsentProvider } from './contexts/AIProcessingConsentContext'
import { getCurrentUser, type User } from './lib/api'
import { setAuthTokenGetter } from './lib/apiAuth'
import { bootstrapWebSession, isWebSessionActive, logoutWebSession, reconcileWebSessionWithClerk, restoreWebSession, setWebOnboardingRequired, setWebSessionActive, webSessionEnabled, webSessionStateChanged } from './lib/webSession'
import { clearPasskeySignInJournal, recoverPendingPasskeySignIn } from './lib/passkeys'
import { migrateAIConsentToStableUser } from './lib/aiConsentStorage'
import { isJoinSetupPath } from './lib/onboarding'

const CLERK_PUBLISHABLE_KEY = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
const isClerkEnabled = Boolean(CLERK_PUBLISHABLE_KEY && CLERK_PUBLISHABLE_KEY !== 'YOUR_PUBLISHABLE_KEY')

const HomePage = lazy(() => import('./pages/HomePage').then((module) => ({ default: module.HomePage })))
const MyLibraryPage = lazy(() => import('./pages/MyLibraryPage').then((module) => ({ default: module.MyLibraryPage })))
const AudioPage = lazy(() => import('./pages/AudioPage').then((module) => ({ default: module.AudioPage })))
const PdfPage = lazy(() => import('./pages/PdfPage').then((module) => ({ default: module.PdfPage })))
const DocsPage = lazy(() => import('./pages/DocsPage').then((module) => ({ default: module.DocsPage })))
const WebhooksPage = lazy(() => import('./pages/WebhooksPage').then((module) => ({ default: module.WebhooksPage })))
const OpsPage = lazy(() => import('./pages/OpsPage').then((module) => ({ default: module.OpsPage })))
const CollectionsPage = lazy(() => import('./pages/CollectionsPage').then((module) => ({ default: module.CollectionsPage })))
const PrivacyPage = lazy(() => import('./pages/PrivacyPage').then((module) => ({ default: module.PrivacyPage })))
const DeleteAccountPage = lazy(() => import('./pages/DeleteAccountPage').then((module) => ({ default: module.DeleteAccountPage })))
const TermsPage = lazy(() => import('./pages/TermsPage').then((module) => ({ default: module.TermsPage })))
const SupportPage = lazy(() => import('./pages/SupportPage').then((module) => ({ default: module.SupportPage })))
const LandingPage = lazy(() => import('./pages/LandingPage').then((module) => ({ default: module.LandingPage })))
const DashboardPage = lazy(() => import('./pages/DashboardPage').then((module) => ({ default: module.DashboardPage })))
const DeveloperPage = lazy(() => import('./pages/DeveloperPage').then((module) => ({ default: module.DeveloperPage })))
const SettingsPage = lazy(() => import('./pages/SettingsPage').then((module) => ({ default: module.SettingsPage })))
const ProcessingPage = lazy(() => import('./pages/ProcessingPage').then((module) => ({ default: module.ProcessingPage })))
const ItemDetailPage = lazy(() => import('./pages/ItemDetailPage').then((module) => ({ default: module.ItemDetailPage })))
const CreatePage = lazy(() => import('./pages/CreatePage').then((module) => ({ default: module.CreatePage })))
const JoinPage = lazy(() => import('./pages/JoinPage').then((module) => ({ default: module.JoinPage })))

if (!isClerkEnabled && !webSessionEnabled) {
  console.warn('Account auth is not configured — using local API-key development mode.')
}

function AppRoutes() {
  return (
    <>
      <ScrollToTop />
      <Suspense fallback={<RouteLoading />}>
        <Routes>
        <Route path="/" element={<LandingPage />} />
        <Route path="/join" element={<JoinPage />} />

      <Route element={<PublicLayout />}>
        <Route path="/docs" element={<DocsPage />} />
        <Route path="/privacy" element={<PrivacyPage />} />
        <Route path="/delete-account" element={<DeleteAccountPage />} />
        <Route path="/terms" element={<TermsPage />} />
        <Route path="/support" element={<SupportPage />} />
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
        <Route path="new" element={<CreatePage />} />
        <Route path="video" element={<HomePage />} />
        <Route path="audio" element={<AudioPage />} />
        <Route path="pdf" element={<PdfPage />} />
        <Route path="library" element={<MyLibraryPage />} />
        <Route path="items/:itemType/:itemId" element={<ItemDetailPage />} />
        <Route path="processing" element={<ProcessingPage />} />
        <Route path="collections" element={<CollectionsPage />} />
        <Route path="collections/:collectionId" element={<CollectionsPage />} />
        <Route path="developer" element={<DeveloperPage />} />
        <Route path="developer/webhooks" element={<WebhooksPage />} />
        <Route path="admin/ops" element={<ProtectedRoute requireOwner><OpsPage /></ProtectedRoute>} />
        <Route path="settings" element={<SettingsPage />} />
      </Route>

        <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Suspense>
    </>
  )
}

function RouteLoading() {
  return <div className="flex min-h-[45vh] items-center justify-center" role="status"><div className="h-8 w-8 animate-spin rounded-full border-2 border-[var(--color-border)] border-t-[var(--color-brand-500)]" /><span className="sr-only">Loading page</span></div>
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
      <header className="sticky top-0 z-50 border-b backdrop-blur" style={{ backgroundColor: 'var(--color-header-bg)', borderColor: 'var(--color-border)' }}>
        <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4">
          <Link to="/" className="flex items-center gap-3">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg" style={{ backgroundColor: 'var(--color-brand-500)' }}>
              <FileText className="h-5 w-5" style={{ color: 'var(--color-on-brand)' }} />
            </div>
            <div>
              <div className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>Media Tools</div>
              <div className="text-xs" style={{ color: 'var(--color-text-muted)' }}>AI media workspace</div>
            </div>
          </Link>
          <nav className="flex items-center gap-2">
            <Link to="/docs" className="min-h-11 rounded-xl px-4 py-3 text-sm font-semibold transition hover:bg-[var(--color-nav-hover)]" style={{ color: 'var(--color-text-secondary)' }}>API docs</Link>
            <Link to="/app" className="min-h-11 rounded-xl px-4 py-3 text-sm font-semibold transition hover:opacity-90" style={{ backgroundColor: 'var(--color-brand-500)', color: 'var(--color-on-brand)' }}>Open app</Link>
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
      <span>Built with Go + React by{' '}<a href="https://github.com/Shimizu-Technology" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--color-brand-500)' }}>Shimizu Technology</a></span>
      <span className="mx-2" aria-hidden="true">·</span>
      <Link to="/privacy" style={{ color: 'var(--color-brand-500)' }}>Privacy</Link>
      <span className="mx-2" aria-hidden="true">·</span>
      <Link to="/terms" style={{ color: 'var(--color-brand-500)' }}>Terms</Link>
      <span className="mx-2" aria-hidden="true">·</span>
      <Link to="/support" style={{ color: 'var(--color-brand-500)' }}>Support</Link>
      <span className="mx-2" aria-hidden="true">·</span>
      <Link to="/delete-account" style={{ color: 'var(--color-brand-500)' }}>Delete account</Link>
    </footer>
  )
}

function ClerkAppContent() {
  const { getToken, isLoaded, isSignedIn, userId } = useAuth()
  const clerk = useClerk()
  const signOut = useCallback(() => clerk.signOut({ redirectUrl: '/' }), [clerk])
  const leaveForOnboarding = useCallback(() => clerk.signOut({ redirectUrl: '/join' }), [clerk])
  const bridge = useMemo<ClerkBridge>(() => ({
    isLoaded,
    isSignedIn: isSignedIn ?? false,
    userId,
    getToken,
    signOut,
    leaveForOnboarding,
  }), [getToken, isLoaded, isSignedIn, leaveForOnboarding, signOut, userId])
  return (
    <AccountAppContent clerk={bridge} />
  )
}

type ClerkBridge = {
  isLoaded: boolean
  isSignedIn: boolean
  userId: string | null | undefined
  getToken: (options?: { skipCache?: boolean }) => Promise<string | null>
  signOut: () => Promise<void>
  leaveForOnboarding: () => Promise<void>
}

function AccountAppContent({ clerk }: { clerk?: ClerkBridge }) {
  const [user, setUser] = useState<User | null>(null)
  const [isUserLoading, setIsUserLoading] = useState(true)
  const [hasWebSession, setHasWebSession] = useState(false)
  const [authBlocked, setAuthBlocked] = useState(false)
  const clerkReady = clerk?.isLoaded ?? true
  const clerkSignedIn = clerk?.isSignedIn ?? false
  const clerkUserId = clerk?.userId ?? null

  useEffect(() => {
    setAuthTokenGetter(async (forceRefresh) => {
      if (!clerk) return null
      try {
        return await clerk.getToken(forceRefresh ? { skipCache: true } : undefined)
      } catch {
        return null
      }
    })
  }, [clerk])

  const refreshUser = useCallback(async () => {
    if (!isWebSessionActive() && !clerkSignedIn) {
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
  }, [clerkSignedIn])

  useEffect(() => {
    const syncWebSessionState = () => {
      const active = isWebSessionActive()
      setHasWebSession(active)
      if (active) void refreshUser()
    }
    window.addEventListener(webSessionStateChanged, syncWebSessionState)
    return () => window.removeEventListener(webSessionStateChanged, syncWebSessionState)
  }, [refreshUser])

  useEffect(() => {
    if (!clerkReady) return
    let cancelled = false
    const restore = async () => {
      // `/join` owns account switching. Its transferred bearer credential is
      // held in a narrow HttpOnly cookie, so ordinary Clerk reconciliation or
      // bootstrap must not clear it before the guided flow can commit it.
      const joiningAccount = isJoinSetupPath(window.location.pathname)
      setIsUserLoading(true)
      setAuthBlocked(false)
      setHasWebSession(false)
      setUser(null)
      if (!clerkSignedIn) localStorage.removeItem('mta_jwt_token')
      try {
        if (webSessionEnabled) {
          setWebSessionActive(false)
          let status = await restoreWebSession()
          if (cancelled) return
          if (!joiningAccount) {
            try { status = await reconcileWebSessionWithClerk(status, clerkUserId) } catch (error) { setAuthBlocked(true); throw error }
          }
          if (cancelled) return
          if (status === null) setWebSessionActive(false)
          if (status !== null) {
            clearPasskeySignInJournal()
            setWebOnboardingRequired(status.onboarding_required === true)
            setWebSessionActive(true)
          }
          if (!isWebSessionActive() && !joiningAccount) {
            const recovered = await recoverPendingPasskeySignIn()
            if (cancelled) return
            if (recovered) status = await restoreWebSession()
            try { status = await reconcileWebSessionWithClerk(status, clerkUserId) } catch (error) { setAuthBlocked(true); throw error }
            if (cancelled) return
            if (status === null) setWebSessionActive(false)
            if (status !== null) {
              setWebOnboardingRequired(status.onboarding_required === true)
              setWebSessionActive(true)
            }
          }
          if (!isWebSessionActive() && !joiningAccount && clerkUserId && clerk) {
            const token = await clerk.getToken()
            if (cancelled) return
            if (token && await bootstrapWebSession(token, clerkUserId)) setWebSessionActive(true)
          }
        }
        if (cancelled) return
        setHasWebSession(isWebSessionActive())
        if (isWebSessionActive() || clerkSignedIn) {
          setUser(await getCurrentUser())
        } else {
          setUser(null)
        }
      } catch {
        if (!cancelled) setUser(null)
      } finally {
        if (!cancelled) setIsUserLoading(false)
      }
    }
    void restore()
    return () => { cancelled = true }
  }, [clerk, clerkReady, clerkSignedIn, clerkUserId])

  const signOut = useCallback(async () => {
    if (isWebSessionActive()) await logoutWebSession()
    setWebSessionActive(false)
    setHasWebSession(false)
    setUser(null)
    if (clerk) await clerk.signOut()
  }, [clerk])

  useEffect(() => {
    if (!hasWebSession || !user?.id || !user.clerk_id) return
    migrateAIConsentToStableUser({ stableUserID: user.id, linkedClerkID: user.clerk_id, activeClerkID: clerkUserId })
  }, [clerkUserId, hasWebSession, user])

  return (
    <AuthProvider
      isClerkEnabled={Boolean(clerk)}
      accountAuthEnabled={true}
      isFirstPartySession={!authBlocked && hasWebSession}
      isPreviousProviderSignedIn={clerkSignedIn}
      isAuthenticated={!authBlocked && (hasWebSession || clerkSignedIn)}
      isLoading={!clerkReady || isUserLoading}
      canUseWorkspace={!authBlocked}
      user={user}
      refreshUser={refreshUser}
      signOut={signOut}
      leavePreviousProviderForOnboarding={clerk?.leaveForOnboarding}
    >
      <AIProcessingConsentProvider ownerID={!authBlocked && hasWebSession ? user?.id ?? null : user?.clerk_id ?? clerkUserId}>
        <AppRoutes />
      </AIProcessingConsentProvider>
    </AuthProvider>
  )
}

function NoClerkAppContent() {
  const [apiKey, setApiKey] = useState(() => localStorage.getItem('mta_api_key'))

  useEffect(() => {
    const check = () => setApiKey(localStorage.getItem('mta_api_key'))
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
      accountAuthEnabled={false}
      isFirstPartySession={false}
      isAuthenticated={Boolean(apiKey)}
      isLoading={false}
      canUseWorkspace={false}
      user={null}
      refreshUser={async () => undefined}
    >
      <APIKeyConsentScope key={apiKey ?? 'no-api-key'} apiKey={apiKey} />
    </AuthProvider>
  )
}

function APIKeyConsentScope({ apiKey }: { apiKey: string | null }) {
  const [ownerID, setOwnerID] = useState<string | null>(null)

  useEffect(() => {
    if (!apiKey) return

    let cancelled = false
    void fingerprintAPIKey(apiKey).then((fingerprint) => {
      if (!cancelled && fingerprint) setOwnerID(`api-key:${fingerprint}`)
    })
    return () => {
      cancelled = true
    }
  }, [apiKey])

  return (
    <AIProcessingConsentProvider ownerID={ownerID}>
      <AppRoutes />
    </AIProcessingConsentProvider>
  )
}

async function fingerprintAPIKey(apiKey: string): Promise<string | null> {
  try {
    if (!globalThis.crypto?.subtle) return null
    const digest = await globalThis.crypto.subtle.digest('SHA-256', new TextEncoder().encode(apiKey))
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')
  } catch {
    // Without a safe, one-way account scope, AI requests remain blocked.
    return null
  }
}

function App() {
  if (!isClerkEnabled) {
    return (
      <BrowserRouter>
        {webSessionEnabled ? <AccountAppContent /> : <NoClerkAppContent />}
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
