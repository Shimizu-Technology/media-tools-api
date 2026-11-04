import { Link } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';
import { useAuthCapabilities } from '../hooks/useAuthCapabilities';
import { PublicFooter, PublicHeader } from '../components/PublicChrome';
import { buttonClass } from '../components/ui/styles';

/**
 * The public front page. Every sentence describes something the product does
 * today; nothing on it is a number, a customer, or a quote we made up.
 */
export function LandingPage() {
  const { accountAuthEnabled, isAuthenticated } = useAuthContext();
  const { state: capabilities } = useAuthCapabilities();
  const canSignUp = accountAuthEnabled && !isAuthenticated && capabilities.status === 'ready' && capabilities.signup;
  const primary = isAuthenticated || !accountAuthEnabled ? { to: '/app', label: 'Open your library' } : { to: '/sign-in', label: 'Sign in' };

  return (
    <div className="flex min-h-dvh flex-col bg-bg text-text">
      <PublicHeader />
      <main className="flex-1">
        <section className="mx-auto grid max-w-6xl items-center gap-12 px-4 pb-20 pt-10 sm:px-8 sm:pt-16 lg:grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)] lg:gap-16 lg:pb-28">
          <div>
            <h1 className="font-serif text-[clamp(2.5rem,6vw,4.75rem)] font-bold leading-[0.98] tracking-[-0.03em] [text-wrap:balance]">
              Record it now. Read it later.
            </h1>
            <p className="mt-7 max-w-[34rem] text-[1.1875rem] leading-8 text-text">
              Media Tools turns a voice memo, a video link or a PDF into a transcript and a short summary, kept in a private library you can search and ask questions of.
            </p>
            <div className="mt-9 flex flex-wrap gap-3">
              <Link to={primary.to} className={buttonClass({ variant: 'primary', size: 'lg' })}>{primary.label}</Link>
              {canSignUp && <Link to="/sign-up" className={buttonClass({ variant: 'secondary', size: 'lg' })}>Create an account</Link>}
            </div>
          </div>
          <ExamplePage />
        </section>

        <section aria-labelledby="ways-heading" className="bg-surface">
          <div className="mx-auto grid max-w-6xl gap-10 px-4 py-20 sm:px-8 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)] lg:py-28">
            <h2 id="ways-heading" className="font-serif text-[clamp(2rem,4.5vw,3.25rem)] font-bold leading-[1.05] tracking-[-0.02em]">Three ways in</h2>
            <dl className="grid gap-9">
              <Way term="Record" body="Press Record in the browser and talk. Every second is kept on your device as you go, so a closed tab or a dropped connection does not lose it." />
              <Way term="Paste a link" body="YouTube, Vimeo and most other video sites. The transcript comes from the video’s captions or its speech." />
              <Way term="Add a file" body="Audio or video files up to 2 GB, and PDFs up to 50 MB. A PDF’s text is kept page by page." />
            </dl>
          </div>
        </section>

        <section aria-labelledby="read-heading" className="mx-auto max-w-6xl px-4 py-20 sm:px-8 lg:py-28">
          <h2 id="read-heading" className="max-w-3xl font-serif text-[clamp(2rem,4.5vw,3.25rem)] font-bold leading-[1.05] tracking-[-0.02em]">Then it waits for you, ready to read</h2>
          <div className="mt-10 grid gap-x-16 gap-y-8 text-[1.0625rem] leading-7 md:grid-cols-2">
            <p><strong className="font-semibold">The summary comes first:</strong> a few sentences, then key points, decisions and follow-ups. It can be written as soon as a recording is transcribed, or whenever you ask.</p>
            <p><strong className="font-semibold">Transcripts are set for reading,</strong> in a serif with room between the lines, with timestamps one tap away and the untouched original kept too.</p>
            <p><strong className="font-semibold">Search covers everything:</strong> titles, transcripts, summaries and tags, across recordings, videos and documents.</p>
            <p><strong className="font-semibold">Ask a question</strong> about one item or a whole collection. Answers point to the moment or the page they came from.</p>
          </div>
        </section>

        <section aria-labelledby="private-heading" className="bg-accent-fill text-on-accent">
          <div className="mx-auto grid max-w-6xl gap-8 px-4 py-20 sm:px-8 lg:grid-cols-2 lg:py-24">
            <h2 id="private-heading" className="font-serif text-[clamp(2rem,4.5vw,3.25rem)] font-bold leading-[1.05] tracking-[-0.02em]">Private, and it asks first</h2>
            <div className="space-y-4 text-[1.0625rem] leading-7">
              <p>Your library belongs to your account and is not published anywhere. Audio goes to OpenAI for transcription, and text goes to OpenRouter for summaries and answers, only after you allow it. You can take that permission back in Settings.</p>
              <p>You can delete your account and everything in it yourself, at any time.</p>
              <p className="flex flex-wrap gap-x-5">
                <Link to="/privacy" className="inline-flex min-h-11 items-center font-semibold underline underline-offset-4">Read the privacy policy</Link>
                <Link to="/docs" className="inline-flex min-h-11 items-center font-semibold underline underline-offset-4">Give an agent its own key</Link>
              </p>
            </div>
          </div>
        </section>
      </main>
      <PublicFooter />
    </div>
  );
}

function Way({ term, body }: { term: string; body: string }) {
  return (
    <div className="grid gap-2 sm:grid-cols-[11rem_minmax(0,1fr)] sm:gap-8">
      <dt className="font-serif text-2xl font-semibold tracking-[-0.01em]">{term}</dt>
      <dd className="text-[1.0625rem] leading-7">{body}</dd>
    </div>
  );
}

/**
 * A real piece of the item page, filled with an example so the reading
 * layout is visible before signing in. It is labelled as an example.
 */
function ExamplePage() {
  return (
    <figure className="min-w-0">
      <div data-ui className="rounded-xl bg-surface px-6 py-7 shadow-overlay sm:px-9 sm:py-9" aria-hidden="true">
        <p className="text-title">Planning call about the launch</p>
        <p className="mt-1.5 text-callout text-text-secondary">Recording · Meetings</p>
        <p className="mt-6 text-heading">Summary</p>
        <p className="mt-2 text-reading">The launch moves back a week so the retry path can be tested properly. Testing is split by platform, and pricing waits until after launch.</p>
        <p className="mt-5 text-subheading">Follow-ups</p>
        <ul className="mt-1.5 list-disc space-y-1 pl-5 text-reading marker:text-text-secondary">
          <li>Send the revised timeline.</li>
          <li>Book the test build.</li>
        </ul>
        <p className="mt-6 text-heading">Transcript</p>
        <p className="mt-2 text-reading text-text-secondary">Okay, so the main thing I wanted to talk through is the date. I don’t think it gives us enough room for the retry work…</p>
      </div>
      <figcaption className="mt-3 text-meta text-text-secondary">An example item page. Your library shows your own recordings.</figcaption>
    </figure>
  );
}
