import { useState, useCallback, useEffect } from 'react'
import { SignInButton } from '@clerk/clerk-react'
import { useSearchParams, useNavigate } from 'react-router-dom'
import { ArrowLeft, LogIn, Video } from 'lucide-react'
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
import { useAuthContext } from '../contexts/useAuthContext'
import { CapturePageHeader } from '../components/CapturePageHeader'

export function HomePage() {
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const { isClerkEnabled, isAuthenticated, isLoading: isAuthLoading } = useAuthContext()
  const [apiKey, setApiKey] = useState(() => localStorage.getItem('mta_api_key') || '')
  const [transcript, setTranscript] = useState<Transcript | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [error, setError] = useState('')

  const canSubmit = isAuthenticated || !!apiKey

  // Load transcript from URL param
  const urlId = searchParams.get('id') || searchParams.get('transcript')
  useEffect(() => {
    if (urlId && !transcript) {
      getTranscript(urlId)
        .then((t) => setTranscript(t))
        .catch(() => setError('Transcript not found'))
    }
    // If URL has no id but we have a transcript from submission, keep it
    // If URL has no id and no transcript, show the input form (normal state)
  }, [urlId, transcript])

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
    }, [transcript]),
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
    navigate('/app/video', { replace: true })
  }

  return (
    <main className="mx-auto max-w-5xl py-4 sm:py-6">
      {!transcript && (
        <CapturePageHeader
          icon={Video}
          eyebrow="Video"
          title="Import a video transcript"
          description="Paste a video link to capture its transcript, generate a focused summary, and ask questions about the content."
          historyTo="/app/library?type=youtube"
          historyLabel="View video library"
          highlights={['1,000+ video sites', 'AI summaries', 'Ask follow-up questions']}
        />
      )}

      {/* Back button */}
      {transcript && (
        <button
          onClick={handleReset}
          className="mb-6 flex min-h-11 items-center gap-1.5 rounded-xl pr-3 text-sm font-medium"
          style={{ color: 'var(--color-brand-500)' }}
        >
          <ArrowLeft className="w-4 h-4" />
          New transcript
        </button>
      )}

      {/* Auth / API Key Setup */}
      {!transcript && isClerkEnabled && !isAuthLoading && !isAuthenticated && (
        <div
          className="max-w-md mx-auto mb-8 p-6 rounded-2xl border text-center"
          style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}
        >
          <div
            className="w-10 h-10 mx-auto mb-3 rounded-xl flex items-center justify-center"
            style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}
          >
            <LogIn className="w-5 h-5" />
          </div>
          <h3 className="text-base font-semibold mb-1" style={{ color: 'var(--color-text-primary)' }}>
            Sign in to extract transcripts
          </h3>
          <p className="text-sm mb-4" style={{ color: 'var(--color-text-muted)' }}>
            Your videos, recordings, PDFs, chats, and collections stay tied to your account.
          </p>
          <SignInButton mode="modal">
            <button
              className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-xl text-sm font-medium text-white transition-opacity hover:opacity-90"
              style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '44px' }}
            >
              <LogIn className="w-4 h-4" />
              Sign in
            </button>
          </SignInButton>
        </div>
      )}

      {!transcript && isClerkEnabled && isAuthLoading && (
        <div className="max-w-2xl mx-auto h-16 rounded-2xl animate-pulse" style={{ backgroundColor: 'var(--color-surface-elevated)' }} />
      )}

      {!transcript && !isClerkEnabled && !apiKey && (
        <div className="mb-8">
          <ApiKeySetup onKeySet={setApiKey} hasKey={!!apiKey} />
        </div>
      )}

      {/* URL Input */}
      {canSubmit && !transcript && (
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
