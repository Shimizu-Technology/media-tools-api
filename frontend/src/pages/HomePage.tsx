import { useState, useCallback, useEffect } from 'react'
import { useSearchParams, Link, useNavigate } from 'react-router-dom'
import { Sparkles, ArrowLeft, History, MessageCircle, Wand2, PlayCircle } from 'lucide-react'
import { ApiKeySetup } from '../components/ApiKeySetup'
import { TranscriptInput } from '../components/TranscriptInput'
import { TranscriptDisplay } from '../components/TranscriptDisplay'
import { SummaryPanel } from '../components/SummaryPanel'
import { TranscriptChatPanel } from '../components/TranscriptChatPanel'
import { usePolling } from '../hooks/usePolling'
import {
  createTranscript,
  getTranscript,
  addTranscriptToHistory,
  type Transcript,
} from '../lib/api'

export function HomePage() {
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const [apiKey, setApiKey] = useState(() => localStorage.getItem('mta_api_key') || '')
  const [transcript, setTranscript] = useState<Transcript | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [error, setError] = useState('')

  // Load transcript from URL param
  const urlId = searchParams.get('id')
  useEffect(() => {
    if (urlId && !transcript) {
      getTranscript(urlId)
        .then((t) => setTranscript(t))
        .catch(() => setError('Transcript not found'))
    }
    // If URL has no id but we have a transcript from submission, keep it
    // If URL has no id and no transcript, show the input form (normal state)
  }, [urlId]) // Only depend on urlId, not transcript

  // Poll for updates
  const shouldPoll = transcript?.status === 'pending' || transcript?.status === 'processing'

  usePolling(
    useCallback(async () => {
      if (!transcript?.id) throw new Error('No transcript')
      const updated = await getTranscript(transcript.id)
      setTranscript(updated)
      if (updated.status === 'completed') {
        addTranscriptToHistory(updated.id)
      }
      return updated
    }, [transcript?.id]),
    {
      enabled: shouldPoll,
      interval: 2000,
      shouldStop: (data: Transcript) => data.status === 'completed' || data.status === 'failed',
    }
  )

  const handleSubmit = async (url: string) => {
    setIsSubmitting(true)
    setError('')
    setTranscript(null)
    try {
      const result = await createTranscript(url)
      setTranscript(result)
      addTranscriptToHistory(result.id)
    } catch (err: unknown) {
      const apiErr = err as { message?: string }
      setError(apiErr.message || 'Failed to extract transcript')
    }
    setIsSubmitting(false)
  }

  const handleReset = () => {
    setTranscript(null)
    setError('')
    // Use navigate instead of setSearchParams to ensure a clean reset
    // This prevents the useEffect from re-loading the old transcript
    navigate('/', { replace: true })
  }

  return (
    <main className="max-w-5xl mx-auto px-4 sm:px-6 py-10 sm:py-14">
      {/* Hero Section */}
      {!transcript && (
        <div className="grid gap-10 lg:grid-cols-[1.2fr_0.8fr] items-start mb-12">
          <div>
            <div
              className="inline-flex items-center gap-2 px-4 py-2 rounded-full text-sm font-medium mb-6"
              style={{
                backgroundColor: 'var(--color-brand-50)',
                color: 'var(--color-brand-500)',
              }}
            >
              <Sparkles className="w-4 h-4" />
              Powered by yt-dlp & OpenRouter AI
            </div>

            <h1
              className="text-4xl md:text-5xl font-semibold tracking-tight mb-4"
              style={{ color: 'var(--color-text-primary)' }}
            >
              Extract YouTube transcripts and chat with the content.
            </h1>

            <p
              className="text-lg max-w-2xl mb-6"
              style={{ color: 'var(--color-text-secondary)' }}
            >
              Paste any YouTube URL to capture the full transcript, generate concise summaries,
              and ask follow-up questions without leaving the page.
            </p>

            <div className="flex flex-wrap items-center gap-3">
              <Link
                to="/library?type=youtube"
                className="inline-flex items-center gap-1.5 text-sm font-medium transition-colors"
                style={{ color: 'var(--color-brand-500)', minHeight: '44px' }}
              >
                <History className="w-4 h-4" />
                View past transcripts
              </Link>
            </div>
          </div>

          <div
            className="rounded-2xl border p-6"
            style={{
              backgroundColor: 'var(--color-surface-elevated)',
              borderColor: 'var(--color-border)',
            }}
          >
            <h2 className="text-sm font-semibold uppercase tracking-[0.2em] mb-4" style={{ color: 'var(--color-text-muted)' }}>
              Flow
            </h2>
            <div className="space-y-4">
              {[
                {
                  icon: <PlayCircle className="w-4 h-4" />,
                  title: 'Paste a link',
                  detail: 'Works with youtube.com, youtu.be, and video IDs.',
                },
                {
                  icon: <Wand2 className="w-4 h-4" />,
                  title: 'Generate insights',
                  detail: 'Summaries, key points, and decisions in one click.',
                },
                {
                  icon: <MessageCircle className="w-4 h-4" />,
                  title: 'Chat with context',
                  detail: 'Ask questions against the transcript and summary.',
                },
              ].map((item) => (
                <div key={item.title} className="flex items-start gap-3">
                  <div
                    className="w-9 h-9 rounded-xl flex items-center justify-center"
                    style={{ backgroundColor: 'var(--color-surface-overlay)', color: 'var(--color-brand-500)' }}
                  >
                    {item.icon}
                  </div>
                  <div>
                    <p className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>
                      {item.title}
                    </p>
                    <p className="text-sm" style={{ color: 'var(--color-text-muted)' }}>
                      {item.detail}
                    </p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Back button */}
      {transcript && (
        <button
          onClick={handleReset}
          className="flex items-center gap-1.5 text-sm font-medium mb-6"
          style={{ color: 'var(--color-brand-500)' }}
        >
          <ArrowLeft className="w-4 h-4" />
          New transcript
        </button>
      )}

      {/* API Key Setup */}
      {!apiKey && (
        <div className="mb-8">
          <ApiKeySetup onKeySet={setApiKey} hasKey={!!apiKey} />
        </div>
      )}

      {/* URL Input */}
      {apiKey && !transcript && (
        <TranscriptInput onSubmit={handleSubmit} isLoading={isSubmitting} />
      )}

      {/* Error */}
      {error && (
        <div
          className="max-w-2xl mx-auto mt-6 p-4 rounded-lg text-sm text-center"
          style={{
            backgroundColor: 'rgba(239, 68, 68, 0.12)',
            color: 'var(--color-error)',
          }}
        >
          {error}
        </div>
      )}

      {/* Transcript Display */}
      {transcript && (
        <div className="mt-6">
          <TranscriptDisplay transcript={transcript} />
          {transcript.status === 'completed' && transcript.transcript_text && (
            <div className="mt-6 grid gap-6 lg:grid-cols-[1.4fr_0.9fr]">
              <div className="lg:col-span-2 h-px" style={{ backgroundColor: 'var(--color-border)' }} />
              <SummaryPanel
                transcriptId={transcript.id}
                transcriptText={transcript.transcript_text}
              />
              <TranscriptChatPanel itemType="transcript" itemId={transcript.id} />
            </div>
          )}
        </div>
      )}
    </main>
  )
}
