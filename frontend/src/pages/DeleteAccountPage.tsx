import { Link } from 'react-router-dom';
import { useAuthContext } from '../contexts/useAuthContext';
import { buttonClass } from '../components/ui/styles';

/** Explains the cross-platform deletion path for people and store reviewers. */
export function DeleteAccountPage() {
  const { isAuthenticated } = useAuthContext();

  return (
    <main className="mx-auto max-w-[60ch] px-4 py-10 text-body leading-7 sm:px-6 sm:py-16">
      <h1 className="text-large-title">Delete your Media Tools account</h1>
      <p className="mt-4">
        You can permanently delete your account from Media Tools on the web or in the iPhone app. The same verified process removes account-owned recordings, transcripts, PDFs, summaries, chats, collections, webhooks, developer keys, and your sign-in identity.
      </p>

      <section className="mt-8 rounded-lg bg-surface p-5">
        <h2 className="text-heading">How deletion works</h2>
        <ol className="mt-2 list-decimal space-y-2 pl-5">
          <li>Sign in to verify that the account belongs to you.</li>
          <li>Open Settings, choose Delete account, and type DELETE.</li>
          <li>Application data is purged immediately. Secure storage and identity-provider cleanup continue automatically if a provider is temporarily unavailable.</li>
        </ol>
      </section>

      <p className="mt-6">
        Deletion cannot be undone. Export anything you want to keep first. On iPhone, device recordings owned by the deleted account are removed as part of the process.
      </p>

      <Link to={isAuthenticated ? '/app/settings' : '/app'} className={buttonClass({ variant: 'primary', className: 'mt-8 min-h-12 w-full rounded-full sm:w-auto' })}>
        {isAuthenticated ? 'Open account settings' : 'Sign in to delete account'}
      </Link>
    </main>
  );
}
