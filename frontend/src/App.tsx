import { lazy, Suspense, useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react'
import { MotionConfig } from 'framer-motion'
import { createBrowserRouter, Navigate, Outlet, RouterProvider, ScrollRestoration, useLocation, type RouteObject } from 'react-router-dom'
import { AppShell } from './components/AppShell'
import { ProtectedRoute } from './components/ProtectedRoute'
import { AuthProvider } from './contexts/AuthContext'
import { AIProcessingConsentProvider } from './contexts/AIProcessingConsentContext'
import { getCurrentUser, isAPIError, type User } from './lib/api'
import { LEGACY_PATHS, legacyRedirect } from './lib/appRoutes'
import { announceSessionChange, sessionAccountChanged, subscribeSessionChanges } from './lib/sessionSync'
import { getSessionPhase, isWebSessionActive, localApiKeyMode, logoutWebSession, restoreWebSession, setSessionPhase, setWebOnboardingRequired, setWebSessionActive, subscribeWebSession, webSessionStateChanged } from './lib/webSession'
import { clearPasskeySignInJournal, recoverPendingPasskeySignIn } from './lib/passkeys'
import { isJoinSetupPath } from './lib/onboarding'
import { PublicFooter, PublicHeader } from './components/PublicChrome'

const LibraryPage = lazy(() => import('./pages/LibraryPage').then((module) => ({ default: module.LibraryPage })))
const CapturePage = lazy(() => import('./pages/CapturePage').then((module) => ({ default: module.CapturePage })))
const ItemDetailPage = lazy(() => import('./pages/ItemDetailPage').then((module) => ({ default: module.ItemDetailPage })))
const SettingsPage = lazy(() => import('./pages/SettingsPage').then((module) => ({ default: module.SettingsPage })))
const DeveloperPage = lazy(() => import('./pages/DeveloperPage').then((module) => ({ default: module.DeveloperPage })))
const WebhooksPage = lazy(() => import('./pages/WebhooksPage').then((module) => ({ default: module.WebhooksPage })))
const OpsPage = lazy(() => import('./pages/OpsPage').then((module) => ({ default: module.OpsPage })))
const DocsPage = lazy(() => import('./pages/DocsPage').then((module) => ({ default: module.DocsPage })))
const PrivacyPage = lazy(() => import('./pages/PrivacyPage').then((module) => ({ default: module.PrivacyPage })))
const DeleteAccountPage = lazy(() => import('./pages/DeleteAccountPage').then((module) => ({ default: module.DeleteAccountPage })))
const TermsPage = lazy(() => import('./pages/TermsPage').then((module) => ({ default: module.TermsPage })))
const SupportPage = lazy(() => import('./pages/SupportPage').then((module) => ({ default: module.SupportPage })))
const LandingPage = lazy(() => import('./pages/LandingPage').then((module) => ({ default: module.LandingPage })))
const SignInPage = lazy(() => import('./pages/AuthPages').then((module) => ({ default: module.SignInPage })))
const SignUpPage = lazy(() => import('./pages/AuthPages').then((module) => ({ default: module.SignUpPage })))
const ForgotPasswordPage = lazy(() => import('./pages/AuthPages').then((module) => ({ default: module.ForgotPasswordPage })))
const JoinPage = lazy(() => import('./pages/JoinPage').then((module) => ({ default: module.JoinPage })))

if (localApiKeyMode) {
  console.warn('Local API-key development mode: this build never ships to production.')
}

/**
 * A data router, so the recorder can hold navigation while it records
 * (useBlocker) and Back restores the Library's scroll position.
 */
const appRoutes: RouteObject[] = [{
  element: <Root />,
  children: [
    { path: '/', element: <LandingOrSharedLink /> },
    { path: '/join', element: <JoinPage /> },
    { path: '/sign-in', element: <SignInPage /> },
    { path: '/sign-up', element: <SignUpPage /> },
    { path: '/forgot-password', element: <ForgotPasswordPage /> },
    {
      element: <PublicLayout />,
      children: [
        { path: '/docs', element: <DocsPage /> },
        { path: '/privacy', element: <PrivacyPage /> },
        { path: '/delete-account', element: <DeleteAccountPage /> },
        { path: '/terms', element: <TermsPage /> },
        { path: '/support', element: <SupportPage /> },
      ],
    },
    ...LEGACY_PATHS.map((path) => ({ path, element: <LegacyRedirect /> })),
    {
      path: '/app',
      element: <ProtectedRoute><AppShell /></ProtectedRoute>,
      children: [
        { index: true, element: <LibraryPage /> },
        { path: 'new', element: <CapturePage /> },
        { path: 'items/:itemType/:itemId', element: <ItemDetailPage /> },
        { path: 'settings', element: <SettingsPage /> },
        { path: 'settings/developer', element: <DeveloperPage /> },
        { path: 'settings/webhooks', element: <WebhooksPage /> },
        { path: 'settings/ops', element: <ProtectedRoute requireOwner><OpsPage /></ProtectedRoute> },
      ],
    },
    { path: '*', element: <Navigate to="/" replace /> },
  ],
}]

function Root() {
  return localApiKeyMode ? <LocalApiKeyApp /> : <AccountAppContent />
}

/** Everything below the auth and consent providers. */
function RootOutlet() {
  return (
    <>
      {/* First loads all share the key "default"; tell them apart by URL. */}
      <ScrollRestoration getKey={(location) => (location.key === 'default' ? `${location.pathname}${location.search}` : location.key)} />
      <Suspense fallback={<RouteLoading />}>
        <Outlet />
      </Suspense>
    </>
  )
}

function RouteLoading() {
  return <div className="flex min-h-[45dvh] items-center justify-center" role="status"><div className="h-6 w-6 animate-spin rounded-full border-2 border-separator border-t-accent" /><span className="sr-only">Loading page</span></div>
}

function LegacyRedirect() {
  const location = useLocation()
  return <Navigate to={legacyRedirect(location.pathname, location.search) ?? '/app'} replace />
}

/** Old shared links were `/?id=<transcript>`. */
function LandingOrSharedLink() {
  const location = useLocation()
  const shared = legacyRedirect('/', location.search)
  return shared ? <Navigate to={shared} replace /> : <LandingPage />
}

function PublicLayout() {
  return (
    <div className="flex min-h-dvh flex-col bg-bg text-text">
      <PublicHeader />
      <div className="flex-1"><Outlet /></div>
      <PublicFooter />
    </div>
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
        <RootOutlet />
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
      <RootOutlet />
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

const router = createBrowserRouter(appRoutes)

function App() {
  return (
    // Framer Motion drops transform animation for people who ask for less motion.
    <MotionConfig reducedMotion="user">
      <RouterProvider router={router} />
    </MotionConfig>
  )
}

export default App
