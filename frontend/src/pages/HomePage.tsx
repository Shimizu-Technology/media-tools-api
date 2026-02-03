import { useState, useCallback, useEffect } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Sparkles, ArrowLeft } from 'lucide-react'
import { ApiKeySetup } from '../components/ApiKeySetup'
import { TranscriptInput } from '../components/TranscriptInput'
import { TranscriptDisplay } from '../components/TranscriptDisplay'
import { SummaryPanel } from '../components/SummaryPanel'
import { usePolling } from '../hooks/usePolling'
import {
  createTranscript,
  getTranscript,
  addTranscriptToHistory,
  type Transcript,
} from '../lib/api'

export function HomePage() {
  const [searchParams, setSearchParams] = useSearchParams()
  const [apiKey, setApiKey] = useState(() => localStorage.getItem('mta_api_key') || '')
  const [transcript, setTranscript] = useState<Transcript | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [error, setError] = useState('')

  // Load transcript from URL param
  useEffect(() => {
    const id = searchParams.get('id')
    if (id && !transcript) {
      getTranscript(id)
        .then((t) => setTranscript(t))
        .catch(() => setError('Transcript not found'))
    }
  }, [searchParams, transcript])

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
    setSearchParams({})
  }

  return (
    <main className="max-w-4xl mx-auto px-4 sm:px-6 py-8 sm:py-12">
      {/* Hero Section */}
      {!transcript && (
        <div className="text-center mb-12">
          <div
            className="inline-flex items-center gap-2 px-4 py-2 rounded-full text-sm font-medium mb-6"
            style={{
              backgroundColor: 'rgba(59, 130, 246, 0.1)',
              color: 'var(--color-brand-400)',
            }}
          >
            <Sparkles className="w-4 h-4" />
            Powered by yt-dlp & OpenRouter AI
          </div>

          <h1
            className="text-4xl md:text-5xl font-bold mb-4"
            style={{ color: 'var(--color-text-primary)' }}
          >
            Extract YouTube{' '}
            <span style={{ color: 'var(--color-brand-500)' }}>Transcripts</span>
          </h1>

          <p
            className="text-lg max-w-xl mx-auto"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            Paste any YouTube URL to extract the full transcript.
            Then generate AI-powered summaries with key points.
          </p>
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
            backgroundColor: 'rgba(239, 68, 68, 0.1)',
            color: '#f87171',
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
            <SummaryPanel
              transcriptId={transcript.id}
              transcriptText={transcript.transcript_text}
            />
          )}
        </div>
      )}
    </main>
  )
}
