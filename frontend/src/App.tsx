import { BrowserRouter, Routes, Route } from 'react-router-dom';

import { Header } from './components/Header';
import { useTheme } from './hooks/useTheme';
import { HomePage } from './pages/HomePage';
import { HistoryPage } from './pages/HistoryPage';
import { DocsPage } from './pages/DocsPage';
import { AudioPage } from './pages/AudioPage';
import { PdfPage } from './pages/PdfPage';

/**
 * Media Tools API — Main Application
 *
 * A clean, multi-page interface for extracting YouTube transcripts
 * and generating AI summaries. Built following the Shimizu Technology
 * frontend design guide.
 *
 * Routes:
 *   /         — Home: URL input + transcript display (MTA-11)
 *   /history  — History dashboard (MTA-13)
 *   /docs     — API documentation (MTA-15)
 *   /audio    — Audio transcription via Whisper (MTA-16)
 *   /pdf      — PDF text extraction (MTA-17)
 */
function App() {
  const { isDark, toggle: toggleTheme } = useTheme();

  return (
    <BrowserRouter>
      <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)' }}>
        <Header isDark={isDark} onToggleTheme={toggleTheme} />

        {/* Background effects */}
        <div className="fixed inset-0 pointer-events-none overflow-hidden">
          <div
            className="absolute top-1/4 -left-1/4 w-96 h-96 rounded-full blur-3xl opacity-20 animate-pulse"
            style={{ backgroundColor: 'var(--color-brand-500)' }}
          />
          <div
            className="absolute top-1/3 -right-1/4 w-96 h-96 rounded-full blur-3xl opacity-10 animate-pulse"
            style={{ backgroundColor: 'var(--color-brand-400)', animationDelay: '1s' }}
          />
        </div>

        {/* Routes */}
        <Routes>
          <Route path="/" element={<HomePage isDark={isDark} />} />
          <Route path="/history" element={<HistoryPage />} />
          <Route path="/audio" element={<AudioPage />} />
          <Route path="/pdf" element={<PdfPage />} />
          <Route path="/docs" element={<DocsPage />} />
        </Routes>

        {/* Footer */}
        <footer
          className="border-t py-8 text-center text-sm"
          style={{
            borderColor: 'var(--color-border)',
            color: 'var(--color-text-muted)',
          }}
        >
          <p>
            Built with Go + React by{' '}
            <a
              href="https://github.com/Shimizu-Technology"
              target="_blank"
              rel="noopener noreferrer"
              className="font-medium transition-colors duration-200"
              style={{ color: 'var(--color-brand-500)' }}
            >
              Shimizu Technology
            </a>
          </p>
        </footer>
      </div>
    </BrowserRouter>
  );
}

export default App;
