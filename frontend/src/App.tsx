import { useState, useCallback } from 'react';
import { motion } from 'framer-motion';
import { Sparkles, ArrowLeft } from 'lucide-react';

import { Header } from './components/Header';
import { TranscriptInput } from './components/TranscriptInput';
import { TranscriptDisplay } from './components/TranscriptDisplay';
import { ApiKeySetup } from './components/ApiKeySetup';
import { useTheme } from './hooks/useTheme';
import { usePolling } from './hooks/usePolling';
import { createTranscript, getTranscript, type Transcript } from './lib/api';

/**
 * Media Tools API — Main Application
 *
 * A clean, single-page interface for extracting YouTube transcripts
 * and generating AI summaries. Built following the Shimizu Technology
 * frontend design guide.
 */
function App() {
  const { isDark, toggle: toggleTheme } = useTheme();
  const [apiKey, setApiKey] = useState(() => localStorage.getItem('mta_api_key') || '');
  const [transcript, setTranscript] = useState<Transcript | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState('');

  // Poll for transcript updates when status is pending/processing
  const shouldPoll = transcript?.status === 'pending' || transcript?.status === 'processing';

  usePolling(
    useCallback(async () => {
      if (!transcript?.id) throw new Error('No transcript');
      const updated = await getTranscript(transcript.id);
      setTranscript(updated);
      return updated;
    }, [transcript?.id]),
    {
      enabled: shouldPoll,
      interval: 2000,
      shouldStop: (data: Transcript) => data.status === 'completed' || data.status === 'failed',
    }
  );

  const handleSubmit = async (url: string) => {
    setIsSubmitting(true);
    setError('');
    setTranscript(null);

    try {
      const result = await createTranscript(url);
      setTranscript(result);
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to extract transcript');
    }
    setIsSubmitting(false);
  };

  const handleReset = () => {
    setTranscript(null);
    setError('');
  };

  return (
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

      {/* Main Content */}
      <main className="relative pt-28 pb-16 px-6">
        {/* Hero section — only show when no transcript is displayed */}
        {!transcript && (
          <div className="text-center mb-12">
            <motion.div
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
              className="inline-flex items-center gap-2 px-4 py-1.5 rounded-full text-sm font-medium mb-6"
              style={{
                backgroundColor: isDark ? 'rgba(59, 130, 246, 0.1)' : 'var(--color-brand-50)',
                color: 'var(--color-brand-500)',
              }}
            >
              <Sparkles className="w-4 h-4" />
              Powered by yt-dlp & OpenRouter AI
            </motion.div>

            <motion.h1
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.6, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
              className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight mb-4"
              style={{ color: 'var(--color-text-primary)' }}
            >
              Extract YouTube{' '}
              <span
                className="bg-clip-text text-transparent"
                style={{
                  backgroundImage: `linear-gradient(135deg, var(--color-brand-400), var(--color-brand-600))`,
                }}
              >
                Transcripts
              </span>
            </motion.h1>

            <motion.p
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.6, delay: 0.2, ease: [0.22, 1, 0.36, 1] }}
              className="text-lg max-w-xl mx-auto"
              style={{ color: 'var(--color-text-secondary)' }}
            >
              Paste any YouTube URL to extract the full transcript.
              Then generate AI-powered summaries with key points.
            </motion.p>
          </div>
        )}

        {/* Back button when viewing a transcript */}
        {transcript && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            className="max-w-2xl mx-auto mb-6"
          >
            <button
              onClick={handleReset}
              className="flex items-center gap-1.5 text-sm font-medium transition-colors duration-200"
              style={{ color: 'var(--color-brand-500)' }}
            >
              <ArrowLeft className="w-4 h-4" />
              New transcript
            </button>
          </motion.div>
        )}

        {/* API Key Setup (shown if no key is stored) */}
        {!apiKey && (
          <div className="mb-8">
            <ApiKeySetup onKeySet={setApiKey} hasKey={!!apiKey} />
          </div>
        )}

        {/* URL Input (shown when we have a key and no transcript) */}
        {apiKey && !transcript && (
          <TranscriptInput onSubmit={handleSubmit} isLoading={isSubmitting} />
        )}

        {/* Error Display */}
        {error && (
          <motion.div
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            className="max-w-2xl mx-auto mt-6 p-4 rounded-xl text-sm text-red-500 text-center"
            style={{
              backgroundColor: isDark ? 'rgba(239, 68, 68, 0.1)' : '#fef2f2',
              border: '1px solid rgba(239, 68, 68, 0.2)',
            }}
          >
            {error}
          </motion.div>
        )}

        {/* Transcript Display */}
        {transcript && (
          <div className="mt-6">
            <TranscriptDisplay transcript={transcript} />
          </div>
        )}
      </main>

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
  );
}

export default App;
