import { Link } from 'react-router-dom';
import { TermsSection } from '../components/legal/TermsSection';

/** Publishes the terms that govern use of Media Tools. */
export function TermsPage() {
  return (
    <main className="mx-auto max-w-3xl px-6 py-16">
      <h1 className="text-3xl font-bold" style={{ color: 'var(--color-text-primary)' }}>Terms of Use</h1>
      <p className="mt-2 text-sm" style={{ color: 'var(--color-text-muted)' }}>Effective August 22, 2026</p>

      <div className="mt-10 space-y-8 leading-relaxed" style={{ color: 'var(--color-text-secondary)' }}>
        <TermsSection title="Agreement and eligibility">
          <p>These terms govern your use of ST Media Tools, provided by Shimizu Technology. You must be at least 13 years old and able to enter a binding agreement where you live. If you use Media Tools for an organization, you confirm that you may accept these terms for it.</p>
        </TermsSection>

        <TermsSection title="Your recordings and content">
          <p>You keep ownership of content you submit. You give us the limited permission needed to host, process, transcribe, format, summarize, and return that content at your direction.</p>
          <p className="mt-3"><strong style={{ color: 'var(--color-text-primary)' }}>You are responsible for having all rights and permissions required to record, upload, or process content.</strong> Recording and consent laws vary by location. Do not secretly or unlawfully record another person.</p>
        </TermsSection>

        <TermsSection title="Acceptable use">
          <p>Do not use Media Tools to violate law or another person’s privacy, intellectual-property, publicity, or other rights; distribute malware; interfere with the service; evade security controls; exploit or harm a child; or create, upload, or request illegal or abusive content. We may restrict access when reasonably necessary to protect people, the service, or comply with law.</p>
        </TermsSection>

        <TermsSection title="AI features">
          <p>AI-generated transcripts, formatting, summaries, citations, and answers can be incomplete or wrong. Review important output against the original source and do not rely on it as professional medical, legal, financial, or safety advice. Media Tools asks before sharing content with third-party AI providers; details and revocation controls are in the <Link to="/privacy#ai-processing" className="underline" style={{ color: 'var(--color-brand-500)' }}>Privacy Policy</Link>.</p>
        </TermsSection>

        <TermsSection title="Service availability and changes">
          <p>We may improve, change, suspend, or discontinue features. We work to keep stored content durable, but you should export anything you cannot afford to lose. The service is provided “as is” and “as available” to the fullest extent permitted by law.</p>
        </TermsSection>

        <TermsSection title="Account deletion and termination">
          <p>You can permanently delete your account in iPhone or web Settings. Public instructions are available on the <Link to="/delete-account" className="underline" style={{ color: 'var(--color-brand-500)' }}>account deletion page</Link>. We may suspend or terminate access for material violations of these terms, security threats, or legal requirements.</p>
        </TermsSection>

        <TermsSection title="Liability">
          <p>To the fullest extent permitted by law, Shimizu Technology is not liable for indirect, incidental, special, consequential, or punitive damages, or for lost data, profits, or opportunities arising from use of Media Tools. Nothing here excludes rights or liability that cannot legally be excluded.</p>
        </TermsSection>

        <TermsSection title="Governing law and contact">
          <p>These terms are governed by the laws applicable in Guam, without regard to conflict-of-law rules. Questions can be sent through our <Link to="/support" className="underline" style={{ color: 'var(--color-brand-500)' }}>support page</Link> or to <a href="mailto:shimizutechnology@gmail.com" className="underline" style={{ color: 'var(--color-brand-500)' }}>shimizutechnology@gmail.com</a>.</p>
        </TermsSection>
      </div>
    </main>
  );
}
