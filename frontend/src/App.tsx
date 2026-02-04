import { useEffect } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { Header } from './components/Header'
import { HomePage } from './pages/HomePage'
import { MyLibraryPage } from './pages/MyLibraryPage'
import { AudioPage } from './pages/AudioPage'
import { PdfPage } from './pages/PdfPage'
import { DocsPage } from './pages/DocsPage'
import { WebhooksPage } from './pages/WebhooksPage'
import { useAuthStore } from './stores/authStore'

function App() {
  const initialize = useAuthStore((s) => s.initialize)

  useEffect(() => {
    initialize()
  }, [initialize])

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
          {/* Redirect old history route to new library */}
          <Route path="/history" element={<Navigate to="/library?type=youtube" replace />} />
        </Routes>

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
    </BrowserRouter>
  )
}

export default App
