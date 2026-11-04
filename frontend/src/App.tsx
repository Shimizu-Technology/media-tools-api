import { lazy, Suspense, useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react'
import { BrowserRouter, Link, Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom'
import { FileText } from 'lucide-react'
import { AppShell } from './components/AppShell'
import { ProtectedRoute } from './components/ProtectedRoute'
import { ScrollToTop } from './components/ScrollToTop'
import { AuthProvider } from './contexts/AuthContext'
import { AIProcessingConsentProvider } from './contexts/AIProcessingConsentContext'
import { getCurrentUser, isAPIError, type User } from './lib/api'
import { announceSessionChange, sessionAccountChanged, subscribeSessionChanges } from './lib/sessionSync'
import { getSessionPhase, isWebSessionActive, localApiKeyMode, logoutWebSession, restoreWebSession, setSessionPhase, setWebOnboardingRequired, setWebSessionActive, subscribeWebSession, webSessionStateChanged } from './lib/webSession'
import { clearPasskeySignInJournal, recoverPendingPasskeySignIn } from './lib/passkeys'
import { isJoinSetupPath } from './lib/onboarding'

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
const SignInPage = lazy(() => import('./pages/AuthPages').then((module) => ({ default: module.SignInPage })))
const SignUpPage = lazy(() => import('./pages/AuthPages').then((module) => ({ default: module.SignUpPage })))
const ForgotPasswordPage = lazy(() => import('./pages/AuthPages').then((module) => ({ default: module.ForgotPasswordPage })))
const JoinPage = lazy(() => import('./pages/JoinPage').then((module) => ({ default: module.JoinPage })))

if (localApiKeyMode) {
  console.warn('Local API-key development mode: this build never ships to production.')
}

function AppRoutes() {
  return (
    <>
      <ScrollToTop />
      <Suspense fallback={<RouteLoading />}>
        <Routes>
        <Route path="/" element={<LandingPage />} />
        <Route path="/join" element={<JoinPage />} />
        <Route path="/sign-in" element={<SignInPage />} />
        <Route path="/sign-up" element={<SignUpPage />} />
        <Route path="/forgot-password" element={<ForgotPasswordPage />} />

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

type RestoreResult = 'authenticated' | 'signed_out' | 'unavailable'

function AccountAppContent() {
  const phase = useSyncExternalStore(subscribeWebSession, getSessionPhase)
  const [user, setUser] = useState<User | null>(null)
  // restore() loads the account itself; the phase listener must not repeat it.
  const restoringRef = useRef(false)
  const loadedUserIDRef = useRef<string | null>(null)
  useEffect(() => { loadedUserIDRef.current = user?.id ?? null }, [user])

  const loadUser = useCallback(async (): Promise<boolean> => {
    try {
      setUser(await getCurrentUser())
      return true
    } catch (error) {
      // An explicit 401 has already signed the browser out through the API
      // client. Anything else (offline, 5xx, throttled) leaves the loaded
      // account on screen: the session is unknown, never assumed gone.
      if (!(isAPIError(error) && error.code === 401)) return false
      setUser(null)
      return true
    }
  }, [])

  const refreshUser = useCallback(async () => {
    if (!isWebSessionActive()) {
      setUser(null)
      return
    }
    await loadUser()
  }, [loadUser])

  const restore = useCallback(async (): Promise<RestoreResult> => {
    // `/join` owns account switching: its transferred credential lives in a
    // narrow HttpOnly cookie that ordinary restoration must not disturb.
    const joiningAccount = isJoinSetupPath(window.location.pathname)
    let restored = await restoreWebSession()
    if (restored.state === 'signed_out' && !joiningAccount) {
      try {
        if (await recoverPendingPasskeySignIn()) restored = await restoreWebSession()
      } catch {
        restored = { state: 'unavailable' }
      }
    }
    if (restored.state === 'authenticated') {
      clearPasskeySignInJournal()
      setWebOnboardingRequired(restored.status.onboarding_required === true)
      restoringRef.current = true
      try { setSessionPhase('authenticated') } finally { restoringRef.current = false }
      if (!await loadUser()) {
        setSessionPhase('unavailable')
        return 'unavailable'
      }
      // loadUser can discover an explicit 401, which signs the browser out.
      return getSessionPhase() === 'authenticated' ? 'authenticated' : 'signed_out'
    }
    setSessionPhase(restored.state)
    if (restored.state === 'signed_out') setUser(null)
    return restored.state
  }, [loadUser])

  // First restore. The API client and sign-in screens move the phase afterwards.
  useEffect(() => {
    const timer = window.setTimeout(() => { void restore() }, 0)
    return () => window.clearTimeout(timer)
  }, [restore])

  // Pick up sign-ins completed by the passkey, recovery and password screens.
  useEffect(() => {
    let lastPhase = getSessionPhase()
    const onChange = () => {
      const current = getSessionPhase()
      if (current === lastPhase) return
      lastPhase = current
      if (current === 'authenticated') {
        announceSessionChange()
        if (!restoringRef.current) {
          void loadUser().then((loaded) => {
            // Signed in but the account can't be read yet: use the retry state,
            // because the app can't work without knowing whose data this is.
            if (!loaded && !loadedUserIDRef.current && getSessionPhase() === 'authenticated') setSessionPhase('unavailable')
          })
        }
      }
      // Never show the previous account's details to whoever signs in next.
      else if (current === 'signed_out') { announceSessionChange(); setUser(null) }
    }
    window.addEventListener(webSessionStateChanged, onChange)
    return () => window.removeEventListener(webSessionStateChanged, onChange)
  }, [loadUser])

  // Another tab may have signed out or switched accounts. Reloading is the one
  // reliable way to drop every piece of state that belongs to the old account.
  useEffect(() => {
    const revalidate = async () => {
      if (getSessionPhase() !== 'authenticated') return
      const restored = await restoreWebSession()
      if (restored.state === 'signed_out') {
        setWebSessionActive(false)
        setUser(null)
      } else if (restored.state === 'authenticated' && sessionAccountChanged(loadedUserIDRef.current, restored.status.user_id)) {
        window.location.reload()
      }
    }
    const onVisible = () => { if (document.visibilityState === 'visible') void revalidate() }
    const unsubscribe = subscribeSessionChanges(() => { void revalidate() })
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      unsubscribe()
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [])

  const retrySession = useCallback(async () => {
    // An established session only needs its account re-read: a failed retry
    // must never replace the app with a full-page error.
    if (getSessionPhase() === 'authenticated') {
      await loadUser()
      return
    }
    await restore()
  }, [loadUser, restore])

  // While the session is unknown, keep asking: when the connection returns,
  // when the tab is foregrounded, and on a gentle backoff.
  useEffect(() => {
    if (phase !== 'unavailable') return
    let delay = 5000
    let timer: number | undefined
    let inFlight = false
    let stopped = false
    // Hidden or offline tabs make no requests, so a forgotten tab can't keep the
    // database awake. One attempt at a time, so slow answers can't pile up.
    const attempt = async () => {
      if (inFlight || document.visibilityState !== 'visible' || !navigator.onLine) return
      inFlight = true
      try { await retrySession() } finally { inFlight = false }
    }
    const schedule = () => {
      timer = window.setTimeout(() => {
        void attempt().finally(() => {
          if (stopped) return
          delay = Math.min(delay * 2, 60000)
          schedule()
        })
      }, delay)
    }
    schedule()
    const onWake = () => { void attempt() }
    window.addEventListener('online', onWake)
    document.addEventListener('visibilitychange', onWake)
    return () => {
      stopped = true
      window.clearTimeout(timer)
      window.removeEventListener('online', onWake)
      document.removeEventListener('visibilitychange', onWake)
    }
  }, [phase, retrySession])

  const signOut = useCallback(async () => {
    if (isWebSessionActive()) await logoutWebSession()
    setWebSessionActive(false)
    setUser(null)
  }, [])

  const isAuthenticated = phase === 'authenticated'

  return (
    <AuthProvider
      accountAuthEnabled={true}
      phase={phase}
      isAuthenticated={isAuthenticated}
      isLoading={phase === 'checking'}
      canUseWorkspace={true}
      user={isAuthenticated ? user : null}
      refreshUser={refreshUser}
      retrySession={retrySession}
      signOut={signOut}
    >
      <AIProcessingConsentProvider ownerID={isAuthenticated ? user?.id ?? null : null}>
        <AppRoutes />
      </AIProcessingConsentProvider>
    </AuthProvider>
  )
}

/** Local development only: `vite dev` with VITE_LOCAL_API_KEY_MODE=true. Never reachable in a production build. */
function LocalApiKeyApp() {
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
      accountAuthEnabled={false}
      phase={apiKey ? 'authenticated' : 'signed_out'}
      isAuthenticated={Boolean(apiKey)}
      isLoading={false}
      canUseWorkspace={false}
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
  return (
    <BrowserRouter>
      {localApiKeyMode ? <LocalApiKeyApp /> : <AccountAppContent />}
    </BrowserRouter>
  )
}

export default App
