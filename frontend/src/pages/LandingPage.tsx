import { Link, Navigate, useSearchParams } from 'react-router-dom';
import { ArrowRight, BookOpen, CheckCircle2, FileText, Library, Lock, Mic, Sparkles } from 'lucide-react';
import { useAuthContext } from '../contexts/useAuthContext';
import { useAuthCapabilities } from '../hooks/useAuthCapabilities';
import { Mark } from '../components/ui/Mark';

const features = [
  { icon: FileText, title: 'Video transcripts', body: 'Capture transcripts from YouTube, Vimeo, and other supported video sites.' },
  { icon: Mic, title: 'Recording transcription', body: 'Upload or record audio, then turn meetings and voice notes into summaries.' },
  { icon: BookOpen, title: 'PDF extraction', body: 'Extract text from documents and bring it into the same searchable library.' },
  { icon: Library, title: 'Media library', body: 'Keep transcripts, recordings, PDFs, chats, summaries, and collections in one workspace.' },
];

export function LandingPage() {
  const [searchParams] = useSearchParams();
  const { accountAuthEnabled, isAuthenticated } = useAuthContext();
  const { state: capabilities } = useAuthCapabilities();
  const canSignUp = capabilities.status === 'ready' && capabilities.signup;
  const hasSharedTranscript = searchParams.has('id') || searchParams.has('transcript');

  if (hasSharedTranscript) {
    return <Navigate to={`/app/video?${searchParams.toString()}`} replace />;
  }

  return (
    <main className="min-h-screen overflow-hidden" style={{ backgroundColor: 'var(--color-bg)', color: 'var(--color-text)' }}>
      <div className="pointer-events-none fixed inset-0 opacity-70" aria-hidden="true">
        <div className="absolute left-1/2 top-[-10rem] h-[28rem] w-[28rem] -translate-x-1/2 rounded-full blur-3xl" style={{ backgroundColor: 'rgba(99, 102, 241, 0.2)' }} />
        <div className="absolute right-[-8rem] top-1/3 h-[24rem] w-[24rem] rounded-full blur-3xl" style={{ backgroundColor: 'rgba(14, 165, 233, 0.14)' }} />
      </div>

      <header className="relative mx-auto flex max-w-7xl items-center justify-between px-4 py-5 sm:px-6 lg:px-8">
        <Link to="/" className="flex items-center gap-3">
          <Mark size={44} />
          <div>
            <p className="font-semibold tracking-tight">Media Tools</p>
            <p className="text-xs" style={{ color: 'var(--color-text-secondary)' }}>Shimizu Technology</p>
          </div>
        </Link>
        <nav className="flex items-center gap-2">
          <Link to="/docs" className="hidden min-h-11 items-center rounded-md px-4 text-sm font-medium transition-colors hover:bg-fill sm:inline-flex" style={{ color: 'var(--color-text-secondary)' }}>API docs</Link>
          {isAuthenticated ? (
            <Link to="/app" className="inline-flex min-h-11 items-center gap-2 rounded-md px-4 text-sm font-semibold text-on-accent transition-colors hover:opacity-90" style={{ backgroundColor: 'var(--color-accent-fill)' }}>
              Open app
              <ArrowRight className="h-4 w-4" />
            </Link>
          ) : accountAuthEnabled ? (
            <Link to="/sign-in" className="inline-flex min-h-11 items-center gap-2 rounded-md px-4 text-sm font-semibold text-on-accent transition-colors hover:opacity-90" style={{ backgroundColor: 'var(--color-accent-fill)' }}>
              Sign in
              <ArrowRight className="h-4 w-4" />
            </Link>
          ) : (
            <Link to="/app" className="inline-flex min-h-11 items-center gap-2 rounded-md px-4 text-sm font-semibold text-on-accent transition-colors hover:opacity-90" style={{ backgroundColor: 'var(--color-accent-fill)' }}>
              Open dev app
              <ArrowRight className="h-4 w-4" />
            </Link>
          )}
        </nav>
      </header>

      <section className="relative mx-auto grid max-w-7xl gap-10 px-4 pb-14 pt-10 sm:px-6 sm:pt-16 lg:grid-cols-[1.05fr_0.95fr] lg:px-8 lg:pb-24 lg:pt-20">
        <div className="max-w-3xl">
          <div className="mb-6 inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.2em]" style={{ borderColor: 'var(--color-separator)', backgroundColor: 'var(--color-surface)', color: 'var(--color-accent)' }}>
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
              <Link to="/app" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-md px-5 text-sm font-semibold text-on-accent transition-colors" style={{ backgroundColor: 'var(--color-accent-fill)' }}>
                Open workspace
                <ArrowRight className="h-4 w-4" />
              </Link>
            ) : accountAuthEnabled ? (
              <>
                <Link to="/sign-in" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-md px-5 text-sm font-semibold text-on-accent transition-colors" style={{ backgroundColor: 'var(--color-accent-fill)' }}>
                  Sign in
                  <ArrowRight className="h-4 w-4" />
                </Link>
                {canSignUp && (
                  <Link to="/sign-up" className="inline-flex min-h-12 items-center justify-center rounded-md border px-5 text-sm font-semibold transition-colors hover:bg-fill" style={{ borderColor: 'var(--color-separator)', color: 'var(--color-text)' }}>
                    Create an account
                  </Link>
                )}
              </>
            ) : (
              <Link to="/app" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-md px-5 text-sm font-semibold text-on-accent transition-colors" style={{ backgroundColor: 'var(--color-accent-fill)' }}>
                Open dev workspace
                <ArrowRight className="h-4 w-4" />
              </Link>
            )}
            <Link to="/docs" className="inline-flex min-h-12 items-center justify-center gap-2 rounded-md border px-5 text-sm font-semibold transition-colors hover:bg-fill" style={{ borderColor: 'var(--color-separator)', color: 'var(--color-text)' }}>
              Read API docs
            </Link>
          </div>
          <div className="mt-8 grid gap-3 text-sm sm:grid-cols-3" style={{ color: 'var(--color-text-secondary)' }}>
            {['Private signed-in workspace', 'API access when you need it', 'Summaries, chat, and collections'].map((item) => (
              <div key={item} className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4" style={{ color: 'var(--color-accent)' }} />
                {item}
              </div>
            ))}
          </div>
        </div>

        <div className="relative">
          <div className="rounded-xl border p-4 shadow-overlay " style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-separator)' }}>
            <div className="rounded-xl border p-5" style={{ backgroundColor: 'var(--color-bg)', borderColor: 'var(--color-separator)' }}>
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-xs font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-text-secondary)' }}>Today</p>
                  <p className="mt-1 text-xl font-semibold">Workspace overview</p>
                </div>
                <div className="flex h-11 w-11 items-center justify-center rounded-lg" style={{ backgroundColor: 'var(--color-accent-tint)', color: 'var(--color-accent)' }}>
                  <Lock className="h-5 w-5" />
                </div>
              </div>
              <div className="mt-6 grid gap-3 sm:grid-cols-2">
                {features.map((feature) => {
                  const Icon = feature.icon;
                  return (
                    <div key={feature.title} className="rounded-lg border p-4" style={{ backgroundColor: 'var(--color-fill)', borderColor: 'var(--color-separator)' }}>
                      <div className="mb-4 flex h-10 w-10 items-center justify-center rounded-md" style={{ backgroundColor: 'var(--color-fill)', color: 'var(--color-accent)' }}>
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
