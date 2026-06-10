import { SignInButton, SignUpButton } from '@clerk/clerk-react';
import { Link, Navigate, useSearchParams } from 'react-router-dom';
import { ArrowRight, BookOpen, CheckCircle2, FileText, Library, Lock, Mic, Sparkles } from 'lucide-react';
import { useAuthContext } from '../contexts/useAuthContext';

const features = [
  { icon: FileText, title: 'Video transcripts', body: 'Capture transcripts from YouTube, Vimeo, and other supported video sites.' },
  { icon: Mic, title: 'Recording transcription', body: 'Upload or record audio, then turn meetings and voice notes into summaries.' },
  { icon: BookOpen, title: 'PDF extraction', body: 'Extract text from documents and bring it into the same searchable library.' },
  { icon: Library, title: 'Media library', body: 'Keep transcripts, recordings, PDFs, chats, summaries, and collections in one workspace.' },
];

export function LandingPage() {
  const [searchParams] = useSearchParams();
  const { isClerkEnabled, isAuthenticated } = useAuthContext();
  const hasSharedTranscript = searchParams.has('id') || searchParams.has('transcript');

  if (hasSharedTranscript) {
    return <Navigate to={`/app/video?${searchParams.toString()}`} replace />;
  }

  return (
    <main className="min-h-screen overflow-hidden" style={{ backgroundColor: 'var(--color-surface)', color: 'var(--color-text-primary)' }}>
      <div className="pointer-events-none fixed inset-0 opacity-70" aria-hidden="true">
        <div className="absolute left-1/2 top-[-10rem] h-[28rem] w-[28rem] -translate-x-1/2 rounded-full blur-3xl" style={{ backgroundColor: 'rgba(99, 102, 241, 0.2)' }} />
        <div className="absolute right-[-8rem] top-1/3 h-[24rem] w-[24rem] rounded-full blur-3xl" style={{ backgroundColor: 'rgba(14, 165, 233, 0.14)' }} />
      </div>

      <header className="relative mx-auto flex max-w-7xl items-center justify-between px-4 py-5 sm:px-6 lg:px-8">
        <Link to="/" className="flex items-center gap-3">
          <div className="flex h-11 w-11 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-500)' }}>
            <FileText className="h-5 w-5 text-white" />
          </div>
          <div>
            <p className="font-semibold tracking-tight">Media Tools</p>
            <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>Shimizu Technology</p>
          </div>
        </Link>
        <nav className="flex items-center gap-2">
          <Link to="/docs" className="hidden min-h-11 items-center rounded-xl px-4 text-sm font-medium transition hover:bg-white/[0.06] sm:inline-flex" style={{ color: 'var(--color-text-secondary)' }}>API docs</Link>
          {isAuthenticated ? (
            <Link to="/app" className="inline-flex min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition hover:opacity-90" style={{ backgroundColor: 'var(--color-brand-500)' }}>
              Open app
              <ArrowRight className="h-4 w-4" />
            </Link>
          ) : isClerkEnabled ? (
            <SignInButton mode="modal" fallbackRedirectUrl="/app">
              <button className="inline-flex min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition hover:opacity-90" style={{ backgroundColor: 'var(--color-brand-500)' }}>
                Sign in
                <ArrowRight className="h-4 w-4" />
              </button>
            </SignInButton>
          ) : (
            <Link to="/app" className="inline-flex min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition hover:opacity-90" style={{ backgroundColor: 'var(--color-brand-500)' }}>
              Open dev app
              <ArrowRight className="h-4 w-4" />
            </Link>
          )}
        </nav>
      </header>

      <section className="relative mx-auto grid max-w-7xl gap-10 px-4 pb-14 pt-10 sm:px-6 sm:pt-16 lg:grid-cols-[1.05fr_0.95fr] lg:px-8 lg:pb-24 lg:pt-20">
        <div className="max-w-3xl">
          <div className="mb-6 inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.2em]" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-elevated)', color: 'var(--color-brand-500)' }}>
            <Sparkles className="h-3.5 w-3.5" />
            AI media workspace
          </div>
          <h1 className="text-5xl font-semibold tracking-tight sm:text-6xl lg:text-7xl">
            A private workspace for the media you need to understand.
          </h1>
          <p className="mt-6 max-w-2xl text-lg leading-8" style={{ color: 'var(--color-text-secondary)' }}>
            Extract transcripts, transcribe recordings, parse PDFs, generate summaries, and chat with every item from a clean signed-in workspace.
          </p>
          <div className="mt-8 flex flex-col gap-3 sm:flex-row">
            {isAuthenticated ? (
              <Link to="/app" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-white transition hover:-translate-y-0.5" style={{ backgroundColor: 'var(--color-brand-500)' }}>
                Open workspace
                <ArrowRight className="h-4 w-4" />
              </Link>
            ) : isClerkEnabled ? (
              <>
                <SignUpButton mode="modal" fallbackRedirectUrl="/app">
                  <button className="inline-flex min-h-12 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-white transition hover:-translate-y-0.5" style={{ backgroundColor: 'var(--color-brand-500)' }}>
                    Create workspace
                    <ArrowRight className="h-4 w-4" />
                  </button>
                </SignUpButton>
                <SignInButton mode="modal" fallbackRedirectUrl="/app">
                  <button className="inline-flex min-h-12 items-center justify-center gap-2 rounded-xl border px-5 text-sm font-semibold transition hover:bg-white/[0.06]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
                    Sign in
                  </button>
                </SignInButton>
              </>
            ) : (
              <Link to="/app" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-white transition hover:-translate-y-0.5" style={{ backgroundColor: 'var(--color-brand-500)' }}>
                Open dev workspace
                <ArrowRight className="h-4 w-4" />
              </Link>
            )}
            <Link to="/docs" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-xl border px-5 text-sm font-semibold transition hover:bg-white/[0.06]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
              Read API docs
            </Link>
          </div>
          <div className="mt-8 grid gap-3 text-sm sm:grid-cols-3" style={{ color: 'var(--color-text-secondary)' }}>
            {['Clerk-secured app routes', 'API keys for developers', 'No emoji UI, production-grade UX'].map((item) => (
              <div key={item} className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4" style={{ color: 'var(--color-success)' }} />
                {item}
              </div>
            ))}
          </div>
        </div>

        <div className="relative">
          <div className="rounded-[2rem] border p-4 shadow-2xl shadow-black/20" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
            <div className="rounded-[1.5rem] border p-5" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-border)' }}>
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-xs font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-text-muted)' }}>Today</p>
                  <p className="mt-1 text-xl font-semibold">Workspace overview</p>
                </div>
                <div className="flex h-11 w-11 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
                  <Lock className="h-5 w-5" />
                </div>
              </div>
              <div className="mt-6 grid gap-3 sm:grid-cols-2">
                {features.map((feature) => {
                  const Icon = feature.icon;
                  return (
                    <div key={feature.title} className="rounded-2xl border p-4" style={{ backgroundColor: 'var(--color-surface-subtle)', borderColor: 'var(--color-border)' }}>
                      <div className="mb-4 flex h-10 w-10 items-center justify-center rounded-xl" style={{ backgroundColor: 'var(--color-surface-overlay)', color: 'var(--color-brand-500)' }}>
                        <Icon className="h-4 w-4" />
                      </div>
                      <p className="font-semibold">{feature.title}</p>
                      <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{feature.body}</p>
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}
