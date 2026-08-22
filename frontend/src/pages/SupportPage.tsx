import { Link } from 'react-router-dom';
import { SupportCard } from '../components/legal/SupportCard';

/** Provides public troubleshooting, safety-reporting, privacy, and recording guidance. */
export function SupportPage() {
  return (
    <main className="mx-auto max-w-3xl px-6 py-16">
      <div className="rounded-[2rem] border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <p className="text-xs font-semibold uppercase tracking-[0.2em]" style={{ color: 'var(--color-brand-500)' }}>Media Tools support</p>
        <h1 className="mt-4 text-3xl font-bold" style={{ color: 'var(--color-text-primary)' }}>Help, safety, and account support</h1>
        <p className="mt-4 leading-7" style={{ color: 'var(--color-text-secondary)' }}>Email <a href="mailto:shimizutechnology@gmail.com" className="font-semibold underline" style={{ color: 'var(--color-brand-500)' }}>shimizutechnology@gmail.com</a>. Include the device, app version, what you were doing, and any visible error. Do not email passwords, API keys, private recordings, or full transcripts.</p>
      </div>

      <div className="mt-8 space-y-6">
        <SupportCard title="Recording or upload problem">
          Keep the saved-on-device recording until support is complete. Export a copy before discarding it. For a failed transcription, include the file type, approximate duration, and the error message—not the media itself unless support specifically requests a secure transfer.
        </SupportCard>
        <SupportCard title="Report harmful or inappropriate AI output">
          Use <strong style={{ color: 'var(--color-text-primary)' }}>Report response</strong> in AI chat or <strong style={{ color: 'var(--color-text-primary)' }}>Report summary</strong> beside a generated summary. The in-app report sends the selected AI output, category, and optional note for review without attaching a separate source recording, transcript, or document. You can also email support about a safety concern, but the in-app report is the fastest way to identify the exact output.
        </SupportCard>
        <SupportCard title="Privacy or account request">
          Review the <Link to="/privacy" className="underline" style={{ color: 'var(--color-brand-500)' }}>Privacy Policy</Link>, manage AI permission in Settings, or follow the public <Link to="/delete-account" className="underline" style={{ color: 'var(--color-brand-500)' }}>account deletion instructions</Link>. Account deletion does not require contacting support.
        </SupportCard>
        <SupportCard title="Recording responsibility">
          Only record or upload content when you have the necessary rights and permission. If someone may be recorded, follow the consent and notice laws that apply where the recording occurs.
        </SupportCard>
      </div>
    </main>
  );
}
