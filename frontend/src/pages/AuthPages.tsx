import { useEffect, useState, type FormEvent } from 'react';
import { Link, Navigate, useLocation, useNavigate, useSearchParams } from 'react-router-dom';
import { KeyRound, Loader2, RefreshCw } from 'lucide-react';
import { AuthLink, AuthShell, Notice } from '../components/auth/AuthShell';
import { CodeField, EmailField, PasswordField, PrimaryButton, SecondaryButton, TextField } from '../components/auth/fields';
import { PasskeySignInButton } from '../components/PasskeySignInButton';
import { RecoveryCodeSignIn } from '../components/RecoveryCodeSignIn';
import { useAuthContext } from '../contexts/useAuthContext';
import { useAuthCapabilities } from '../hooks/useAuthCapabilities';
import { AccountAuthError, finishPasswordReset, startPasswordReset, startSignup, verifySignup } from '../lib/accountAuth';
import { safeNextPath } from '../lib/authRedirect';
import { PasswordError, signInWithPassword } from '../lib/passwords';
import { clearSignInHint, peekSignInHint } from '../lib/webSession';

type RouteState = { email?: string; notice?: string } | null;

/** Waits for the session check and the server's feature flags before drawing a form. */
function useAuthScreenGate() {
  const { isAuthenticated, isLoading, isUnavailable, retrySession } = useAuthContext();
  const capabilities = useAuthCapabilities();
  const [params] = useSearchParams();
  const next = safeNextPath(params.get('next'));
  return { isAuthenticated, isLoading, isUnavailable, retrySession, capabilities, next };
}

function CheckingCard({ title }: { title: string }) {
  return (
    <AuthShell title={title}>
      <div className="flex items-center gap-3 text-sm" role="status" style={{ color: 'var(--color-text-secondary)' }}>
        <Loader2 className="h-4 w-4 animate-spin" />Checking your connection…
      </div>
    </AuthShell>
  );
}

function UnreachableCard({ title, onRetry, busy }: { title: string; onRetry: () => void; busy: boolean }) {
  return (
    <AuthShell title={title}>
      <Notice tone="error">Could not reach Media Tools. Nothing was lost. Check your connection and try again.</Notice>
      <div className="mt-4"><PrimaryButton type="button" onClick={onRetry} busy={busy} busyLabel="Checking…">Try again</PrimaryButton></div>
    </AuthShell>
  );
}

export function SignInPage() {
  const gate = useAuthScreenGate();
  const location = useLocation();
  const [hint] = useState<RouteState>(() => peekSignInHint() ?? (location.state as RouteState));
  const routeState = hint;
  const [email, setEmail] = useState(routeState?.email ?? '');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<{ message: string; code: string } | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const { state, checking, refresh } = gate.capabilities;
  useEffect(() => { clearSignInHint(); }, []);

  if (gate.isAuthenticated) return <Navigate to={gate.next} replace />;
  if (gate.isLoading) return <CheckingCard title="Sign in" />;
  if (gate.isUnavailable) return <UnreachableCard title="Sign in" onRetry={() => void gate.retrySession()} busy={false} />;
  if (state.status === 'unknown') return <UnreachableCard title="Sign in" onRetry={() => void refresh()} busy={checking} />;

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      await signInWithPassword(email, password);
      setPassword('');
    } catch (caught) {
      setError(caught instanceof PasswordError
        ? { message: caught.message, code: caught.code }
        : { message: 'Could not sign in. Try again.', code: 'unknown' });
    } finally {
      setSubmitting(false);
    }
  };

  const resetState = { email: email.trim() };
  return (
    <AuthShell
      title="Sign in"
      intro="Your recordings, transcripts and PDFs, on every device."
      footer={state.signup ? <>New to Media Tools? <AuthLink to="/sign-up">Create an account</AuthLink></> : undefined}
    >
      <div className="space-y-5">
        {routeState?.notice && <Notice tone="success">{routeState.notice}</Notice>}
        {state.passwordAuth ? (
          <form onSubmit={(event) => void submit(event)} className="space-y-4" noValidate>
            <EmailField value={email} onChange={(event) => { setEmail(event.target.value); if (error) setError(null); }} autoComplete="username" required />
            <div>
              <PasswordField label="Password" value={password} onChange={(event) => { setPassword(event.target.value); if (error) setError(null); }} autoComplete="current-password" required />
              <div className="mt-1 flex justify-end">
                <AuthLink to="/forgot-password" state={resetState}>Forgot password?</AuthLink>
              </div>
            </div>
            {error && (
              <Notice tone="error">
                <span className="block">{error.message}</span>
                {error.code === 'invalid_credentials' && <span className="mt-1 block">Never set a password? <Link to="/forgot-password" state={resetState} className="font-semibold underline">Set one with an emailed code</Link>.</span>}
              </Notice>
            )}
            <PrimaryButton type="submit" busy={submitting} busyLabel="Signing in…" disabled={!email.trim() || !password}>Sign in</PrimaryButton>
          </form>
        ) : (
          <Notice tone="info">Email sign-in is not available yet. Use a passkey or recovery code below.</Notice>
        )}

        {state.passwordReset && (
          <div className="rounded-lg border p-4" style={{ borderColor: 'var(--color-separator)', backgroundColor: 'var(--color-fill)' }}>
            <p className="text-sm font-semibold">Already use Media Tools? Set your password first.</p>
            <p className="mt-1 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
              If you signed in before with a different method, your account has no password yet. We email a code to the address on your account and you choose one.
            </p>
            <div className="mt-3"><Link to="/forgot-password" state={resetState} className="inline-flex min-h-11 items-center justify-center rounded-md border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-separator)' }}>Set or reset my password</Link></div>
          </div>
        )}

        <div className="space-y-2 border-t pt-4" style={{ borderColor: 'var(--color-separator)' }}>
          <p className="text-xs font-semibold uppercase tracking-[0.16em]" style={{ color: 'var(--color-text-secondary)' }}>Other ways in</p>
          <PasskeySignInButton variant="secondary" className="w-full" />
          <RecoveryCodeSignIn className="w-full" />
        </div>
      </div>
    </AuthShell>
  );
}

export function SignUpPage() {
  const gate = useAuthScreenGate();
  const { state, checking, refresh } = gate.capabilities;
  if (gate.isAuthenticated) return <Navigate to={gate.next} replace />;
  if (gate.isLoading) return <CheckingCard title="Create your account" />;
  if (gate.isUnavailable) return <UnreachableCard title="Create your account" onRetry={() => void gate.retrySession()} busy={false} />;
  if (state.status === 'unknown') return <UnreachableCard title="Create your account" onRetry={() => void refresh()} busy={checking} />;
  if (!state.signup) {
    return (
      <AuthShell title="Create your account" footer={<AuthLink to="/sign-in">Back to sign in</AuthLink>}>
        <Notice tone="info">Creating accounts is not open yet. If you already have an account, sign in or set your password.</Notice>
      </AuthShell>
    );
  }
  return <EmailCodeFlow mode="signup" />;
}

export function ForgotPasswordPage() {
  const gate = useAuthScreenGate();
  const { state, checking, refresh } = gate.capabilities;
  if (gate.isAuthenticated) return <Navigate to={gate.next} replace />;
  if (gate.isLoading) return <CheckingCard title="Set or reset your password" />;
  if (gate.isUnavailable) return <UnreachableCard title="Set or reset your password" onRetry={() => void gate.retrySession()} busy={false} />;
  if (state.status === 'unknown') return <UnreachableCard title="Set or reset your password" onRetry={() => void refresh()} busy={checking} />;
  if (!state.passwordReset) {
    return (
      <AuthShell title="Set or reset your password" footer={<AuthLink to="/sign-in">Back to sign in</AuthLink>}>
        <Notice tone="info">Password reset by email is not available yet.</Notice>
      </AuthShell>
    );
  }
  return <EmailCodeFlow mode="reset" />;
}

const RESEND_SECONDS = 60;

/** Sign-up and reset share one shape: email, then the emailed code plus a new password. */
function EmailCodeFlow({ mode }: { mode: 'signup' | 'reset' }) {
  const navigate = useNavigate();
  const location = useLocation();
  const routeState = location.state as RouteState;
  const signup = mode === 'signup';
  const [step, setStep] = useState<'request' | 'confirm'>('request');
  const [email, setEmail] = useState(routeState?.email ?? '');
  const [name, setName] = useState('');
  const [code, setCode] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [resendIn, setResendIn] = useState(0);
  const [resent, setResent] = useState(false);

  useEffect(() => {
    if (resendIn <= 0) return;
    const timer = window.setTimeout(() => setResendIn((value) => value - 1), 1000);
    return () => window.clearTimeout(timer);
  }, [resendIn]);

  const request = async (event?: FormEvent) => {
    event?.preventDefault();
    setBusy(true);
    setError('');
    try {
      await (signup ? startSignup(email, name) : startPasswordReset(email));
      setStep('confirm');
      setResendIn(RESEND_SECONDS);
    } catch (caught) {
      setError(caught instanceof AccountAuthError ? caught.message : 'Something went wrong. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const resend = async () => {
    setBusy(true);
    setError('');
    setResent(false);
    try {
      await (signup ? startSignup(email, name) : startPasswordReset(email));
      setCode('');
      setResent(true);
      setResendIn(RESEND_SECONDS);
    } catch (caught) {
      setError(caught instanceof AccountAuthError ? caught.message : 'Could not send another code.');
      if (caught instanceof AccountAuthError && caught.retryAfterSeconds) setResendIn(caught.retryAfterSeconds);
    } finally {
      setBusy(false);
    }
  };

  const confirm = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      await (signup ? verifySignup(email, code, password) : finishPasswordReset(email, code, password));
      setCode('');
      setPassword('');
      navigate('/sign-in', {
        replace: true,
        state: {
          email: email.trim(),
          notice: signup
            ? 'Your account is ready. Sign in with the password you just chose.'
            : 'Password saved. Every device was signed out, so sign in with your new password.',
        } satisfies RouteState,
      });
    } catch (caught) {
      setError(caught instanceof AccountAuthError ? caught.message : 'Something went wrong. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const title = signup ? 'Create your account' : 'Set or reset your password';
  const footer = signup
    ? <>Have an account? <AuthLink to="/sign-in">Sign in</AuthLink></>
    : <AuthLink to="/sign-in">Back to sign in</AuthLink>;

  if (step === 'request') {
    return (
      <AuthShell
        title={title}
        intro={signup
          ? 'Enter your email. We send a 6-digit code to confirm it.'
          : 'Enter the email on your account. We send a 6-digit code, then you choose a password. This also works if you never set one.'}
        footer={footer}
      >
        <form onSubmit={(event) => void request(event)} className="space-y-4" noValidate>
          {signup && <TextField label="Name (optional)" value={name} onChange={(event) => setName(event.target.value)} autoComplete="name" />}
          <EmailField value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="email" required />
          {error && <Notice tone="error">{error}</Notice>}
          <PrimaryButton type="submit" busy={busy} busyLabel="Sending…" disabled={!email.trim()}>Email me a code</PrimaryButton>
          {signup && <p className="text-xs leading-5" style={{ color: 'var(--color-text-secondary)' }}>By continuing you agree to the <Link to="/terms" className="underline">Terms</Link> and <Link to="/privacy" className="underline">Privacy Policy</Link>.</p>}
        </form>
      </AuthShell>
    );
  }

  return (
    <AuthShell
      title="Check your email"
      intro={<>If this request is eligible, an email will arrive shortly at <strong className="break-all" style={{ color: 'var(--color-text)' }}>{email.trim()}</strong>. Enter the code and choose a password.</>}
      footer={footer}
    >
      <form onSubmit={(event) => void confirm(event)} className="space-y-4" noValidate>
        <CodeField value={code} onChange={(value) => { setCode(value); if (error) setError(''); }} disabled={busy} />
        <PasswordField
          label={signup ? 'Password' : 'New password'}
          value={password}
          onChange={(event) => { setPassword(event.target.value); if (error) setError(''); }}
          autoComplete="new-password"
          hint="12 to 128 characters. A password manager or a few words together works well."
          disabled={busy}
          required
        />
        {resent && !error && <Notice tone="info">If this request is eligible, another email is on its way.</Notice>}
        {error && <Notice tone="error">{error}</Notice>}
        <PrimaryButton type="submit" busy={busy} busyLabel={signup ? 'Creating account…' : 'Saving…'} disabled={code.length !== 6 || password.length < 12}>
          {signup ? 'Create account' : 'Save password'}
        </PrimaryButton>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <SecondaryButton type="button" onClick={() => void resend()} disabled={busy || resendIn > 0}>
            <RefreshCw className="h-4 w-4" />{resendIn > 0 ? `Send another in ${resendIn}s` : 'Send another code'}
          </SecondaryButton>
          <button type="button" onClick={() => { setStep('request'); setCode(''); setPassword(''); setError(''); setResent(false); }} className="min-h-11 px-2 text-sm font-semibold underline-offset-4 hover:underline" style={{ color: 'var(--color-accent)' }}>
            Use a different email
          </button>
        </div>
        <p className="flex items-start gap-2 text-xs leading-5" style={{ color: 'var(--color-text-secondary)' }}>
          <KeyRound className="mt-0.5 h-3.5 w-3.5 shrink-0" />Check spam if nothing arrives within a minute. Never share this code with anyone.
        </p>
      </form>
    </AuthShell>
  );
}
