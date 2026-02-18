import { ClerkProvider, SignedIn, SignedOut, SignInButton } from '@clerk/clerk-react'
import { ClerkTokenSync } from './components/ClerkTokenSync'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { Header } from './components/Header'
import { HomePage } from './pages/HomePage'
import { MyLibraryPage } from './pages/MyLibraryPage'
import { AudioPage } from './pages/AudioPage'
import { PdfPage } from './pages/PdfPage'
import { DocsPage } from './pages/DocsPage'
import { WebhooksPage } from './pages/WebhooksPage'
import { OpsPage } from './pages/OpsPage'

const CLERK_PUBLISHABLE_KEY = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AppContent() {
  return (
    <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)' }}>
      <ClerkTokenSync />
      <Header />
      
      <SignedIn>
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/library" element={<MyLibraryPage />} />
          <Route path="/audio" element={<AudioPage />} />
          <Route path="/pdf" element={<PdfPage />} />
          <Route path="/docs" element={<DocsPage />} />
          <Route path="/webhooks" element={<WebhooksPage />} />
          <Route path="/ops" element={<OpsPage />} />
          <Route path="/history" element={<Navigate to="/library?type=youtube" replace />} />
        </Routes>
      </SignedIn>

      <SignedOut>
        <div className="flex flex-col items-center justify-center min-h-[60vh] gap-6 px-4">
          <div className="text-center max-w-md">
            <h1 className="text-3xl font-bold mb-3" style={{ color: 'var(--color-text)' }}>
              Media Tools
            </h1>
            <p className="text-lg mb-6" style={{ color: 'var(--color-text-muted)' }}>
              Transcribe YouTube videos, audio files, and extract text from PDFs. Sign in to get started.
            </p>
            <SignInButton mode="modal">
              <button
                className="px-6 py-3 rounded-lg font-semibold text-white transition-all hover:opacity-90"
                style={{ backgroundColor: 'var(--color-brand-500)' }}
              >
                Sign In
              </button>
            </SignInButton>
          </div>
        </div>
      </SignedOut>

      <footer className="py-8 text-center text-sm" style={{ color: 'var(--color-text-muted)' }}>
        Built with Go + React by{' '}
        <a
          href="https://github.com/Shimizu-Technology"
          target="_blank"
          rel="noopener noreferrer"
          style={{ color: 'var(--color-brand-500)' }}
        >
          Shimizu Technology
        </a>
      </footer>
    </div>
  )
}

function App() {
  // If Clerk is not configured, render without auth (dev/API-key mode)
  if (!CLERK_PUBLISHABLE_KEY) {
    return (
      <BrowserRouter>
        <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)' }}>
          <Header />
          <Routes>
            <Route path="/" element={<HomePage />} />
            <Route path="/library" element={<MyLibraryPage />} />
            <Route path="/audio" element={<AudioPage />} />
            <Route path="/pdf" element={<PdfPage />} />
            <Route path="/docs" element={<DocsPage />} />
            <Route path="/webhooks" element={<WebhooksPage />} />
            <Route path="/ops" element={<OpsPage />} />
            <Route path="/history" element={<Navigate to="/library?type=youtube" replace />} />
          </Routes>
          <footer className="py-8 text-center text-sm" style={{ color: 'var(--color-text-muted)' }}>
            Built with Go + React by{' '}
            <a href="https://github.com/Shimizu-Technology" target="_blank" rel="noopener noreferrer"
              style={{ color: 'var(--color-brand-500)' }}>
              Shimizu Technology
            </a>
          </footer>
        </div>
      </BrowserRouter>
    )
  }

  return (
    <ClerkProvider publishableKey={CLERK_PUBLISHABLE_KEY}>
      <BrowserRouter>
        <AppContent />
      </BrowserRouter>
    </ClerkProvider>
  )
}

export default App
