/**
 * Privacy Policy page — required for App Store submission.
 * Accessible at /privacy (no auth required).
 */
export function PrivacyPage() {
  return (
    <div className="max-w-3xl mx-auto px-6 py-16">
      <h1
        className="text-3xl font-bold mb-2"
        style={{ color: 'var(--color-text-primary)' }}
      >
        Privacy Policy
      </h1>
      <p
        className="text-sm mb-10"
        style={{ color: 'var(--color-text-muted)' }}
      >
        Last updated: February 21, 2026
      </p>

      <div className="space-y-8" style={{ color: 'var(--color-text-secondary)' }}>
        <Section title="Overview">
          <p>
            ST Media Tools ("Media Tools", "we", "our") is a media transcription
            and AI-powered analysis platform built by Shimizu Technology. This
            policy explains how we collect, use, and protect your information
            when you use our iOS app and web application.
          </p>
        </Section>

        <Section title="Information We Collect">
          <ul className="list-disc pl-5 space-y-2">
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>Account information</strong> —
              When you sign in via Clerk (Google, email, etc.), we receive your
              name and email address for authentication purposes.
            </li>
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>Media content</strong> —
              Audio recordings, video URLs, and PDF files you upload for
              transcription and analysis. Audio files are stored securely on
              Amazon S3.
            </li>
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>Transcriptions and summaries</strong> —
              Text generated from your media content, including AI-generated
              summaries, key points, and action items.
            </li>
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>Chat conversations</strong> —
              Messages you send when chatting with AI about your content.
            </li>
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>Microphone access</strong> —
              The iOS app requests microphone permission solely for recording
              audio within the app. We do not access the microphone in the
              background.
            </li>
          </ul>
        </Section>

        <Section title="How We Use Your Information">
          <ul className="list-disc pl-5 space-y-2">
            <li>To transcribe your audio and video content using OpenAI Whisper</li>
            <li>To generate AI-powered summaries and enable AI chat about your content</li>
            <li>To store and organize your media library and collections</li>
            <li>To authenticate your account and protect your data</li>
          </ul>
        </Section>

        <Section title="Third-Party Services">
          <ul className="list-disc pl-5 space-y-2">
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>Clerk</strong> —
              Authentication provider.{' '}
              <a href="https://clerk.com/privacy" className="underline" style={{ color: 'var(--color-brand-500)' }}>
                Privacy policy
              </a>
            </li>
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>OpenAI (Whisper)</strong> —
              Audio transcription.{' '}
              <a href="https://openai.com/privacy" className="underline" style={{ color: 'var(--color-brand-500)' }}>
                Privacy policy
              </a>
            </li>
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>OpenRouter</strong> —
              AI chat and summarization.{' '}
              <a href="https://openrouter.ai/privacy" className="underline" style={{ color: 'var(--color-brand-500)' }}>
                Privacy policy
              </a>
            </li>
            <li>
              <strong style={{ color: 'var(--color-text-primary)' }}>Amazon S3</strong> —
              Secure file storage for uploaded audio.
            </li>
          </ul>
        </Section>

        <Section title="Data Retention">
          <p>
            Your content is stored as long as your account is active. You can
            delete individual items (transcriptions, audio recordings, PDFs) at
            any time from your library. Deleted items are permanently removed
            from our servers and storage.
          </p>
        </Section>

        <Section title="Data Security">
          <p>
            All data is transmitted over HTTPS. Audio files are stored in
            encrypted Amazon S3 buckets. Authentication is handled by Clerk
            with industry-standard security practices.
          </p>
        </Section>

        <Section title="Your Rights">
          <p>
            You can access, export, or delete your data at any time through the
            app. To request complete account deletion, contact us at the email
            below.
          </p>
        </Section>

        <Section title="Contact">
          <p>
            If you have questions about this privacy policy, contact us at:{' '}
            <a
              href="mailto:shimizutechnology@gmail.com"
              className="underline"
              style={{ color: 'var(--color-brand-500)' }}
            >
              shimizutechnology@gmail.com
            </a>
          </p>
        </Section>
      </div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h2
        className="text-lg font-semibold mb-3"
        style={{ color: 'var(--color-text-primary)' }}
      >
        {title}
      </h2>
      <div className="leading-relaxed">{children}</div>
    </section>
  );
}
