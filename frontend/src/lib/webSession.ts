/**
 * Same-origin browser session.
 *
 * Cookie sessions are the only browser auth in a production build. The refresh
 * credential is HttpOnly and never enters JavaScript. Local API-key development
 * mode exists only in `vite dev` (see `localApiKeyMode`), so a production bundle
 * can never fall back to a key stored in the browser.
 */
export const localApiKeyMode = import.meta.env.DEV && import.meta.env.VITE_LOCAL_API_KEY_MODE === 'true';
export const webSessionEnabled = !localApiKeyMode;

/**
 * - `checking`: first restore is in flight.
 * - `authenticated`: the server confirmed a session.
 * - `signed_out`: the server explicitly said there is no usable session.
 * - `unavailable`: the server could not be asked (offline, 5xx, throttled). The
 *   session is unknown, never assumed gone, so the UI offers a retry.
 */
export type SessionPhase = 'checking' | 'authenticated' | 'signed_out' | 'unavailable';

let phase: SessionPhase = 'checking';
let onboardingRequired = false;
let degraded = false;
const listeners = new Set<() => void>();
export const webSessionStateChanged = 'mta:web-session-state-changed';

function notify() {
  listeners.forEach((listener) => listener());
  if (typeof window !== 'undefined') window.dispatchEvent(new CustomEvent(webSessionStateChanged));
}

export function subscribeWebSession(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

export function getSessionPhase(): SessionPhase { return phase; }
export function isWebSessionActive(): boolean { return webSessionEnabled && phase === 'authenticated'; }
export function isWebOnboardingRequired(): boolean { return webSessionEnabled && onboardingRequired; }
/** True while an established session cannot reach the server. */
export function isConnectionDegraded(): boolean { return degraded; }

export function setSessionPhase(next: SessionPhase): void {
  const changed = phase !== next;
  phase = next;
  if (next !== 'authenticated') onboardingRequired = false;
  // A signed-out or fresh session has no stale connection problem to show.
  if (next === 'signed_out' || next === 'authenticated') degraded = false;
  if (changed) notify();
}

export function setWebSessionActive(value: boolean): void {
  setSessionPhase(value ? 'authenticated' : 'signed_out');
}

export function setWebOnboardingRequired(value: boolean): void {
  if (onboardingRequired === value) return;
  onboardingRequired = value;
  notify();
}

/** Called by the API client: a network failure or 5xx never signs anyone out. */
export function setConnectionDegraded(value: boolean): void {
  if (degraded === value) return;
  degraded = value;
  notify();
}

export type SignInHint = { email?: string; notice?: string };
let signInHint: SignInHint | null = null;

/**
 * Remembered across the redirect when the server ends every session (email
 * change). A route-state message can be lost to the route guard's own redirect.
 */
export function setSignInHint(hint: SignInHint): void { signInHint = hint; }
export function peekSignInHint(): SignInHint | null { return signInHint; }
export function clearSignInHint(): void { signInHint = null; }

/** Test seam: restore module state between tests. */
export function resetWebSessionState(): void {
  phase = 'checking';
  onboardingRequired = false;
  degraded = false;
  signInHint = null;
}

const base = '/api/v1/auth/web/session';
export type WebSessionRenewal = 'renewed' | 'invalid' | 'retry';
let renewal: Promise<WebSessionRenewal> | null = null;
export type WebSessionStatus = { authenticated: true; user_id: string; onboarding_required?: boolean };

export type WebSessionRestore =
  | { state: 'authenticated'; status: WebSessionStatus }
  | { state: 'signed_out' }
  | { state: 'unavailable' };

function csrfToken(): string {
  const value = document.cookie.split('; ').find((part) => part.startsWith('mta_web_csrf='));
  return value ? decodeURIComponent(value.slice('mta_web_csrf='.length)) : '';
}

export function webCSRFHeaders(): Record<string, string> {
  const token = csrfToken();
  return token ? { 'X-CSRF-Token': token } : {};
}

export async function renewWebSession(): Promise<WebSessionRenewal> {
  if (renewal) return renewal;
  renewal = (async (): Promise<WebSessionRenewal> => {
    const headers = webCSRFHeaders();
    // Without the readable double-submit cookie this browser cannot renew. That
    // is a local fact, not a server outage, and sign-in issues a fresh one.
    if (!headers['X-CSRF-Token']) return 'invalid';
    const first = await prepareAndRefresh(headers);
    if (first === 'stale_pending') {
      const second = await prepareAndRefresh(headers);
      // A pending successor that stays stale is not proof the session is gone.
      return second === 'stale_pending' ? 'retry' : second;
    }
    return first;
  })().catch(() => 'retry' as const).finally(() => { renewal = null; });
  return renewal;
}

type PreparedRefreshResult = WebSessionRenewal | 'stale_pending';

async function prepareAndRefresh(headers: Record<string, string>): Promise<PreparedRefreshResult> {
  const prepare = await fetch(`${base}/prepare`, { method: 'POST', headers, credentials: 'same-origin' });
  if (!prepare.ok) return classifyRenewalFailure(prepare);
  const refresh = await fetch(`${base}/refresh`, { method: 'POST', headers, credentials: 'same-origin' });
  if (refresh.ok) return 'renewed';
  if (await isStalePendingRefresh(refresh)) return 'stale_pending';
  return classifyRenewalFailure(refresh);
}

async function isStalePendingRefresh(response: Response): Promise<boolean> {
  if (response.status !== 400) return false;
  const body = await response.clone().json().catch(() => null) as { error?: string } | null;
  return body?.error === 'invalid_request' || body?.error === 'refresh_not_prepared';
}

/**
 * Only the server saying the session is invalid (401 from prepare or refresh)
 * signs the browser out. 5xx, throttling, a CSRF/Origin refusal, a proxy
 * error page and every unrecognised status keep the session and ask for a retry.
 */
export function classifyRenewalFailure(response: Response): WebSessionRenewal {
  return response.status === 401 ? 'invalid' : 'retry';
}

export async function restoreWebSession(): Promise<WebSessionRestore> {
  try {
    const first = await fetchStatus();
    if (first.state !== 'signed_out') return first;
    const outcome = await renewWebSession();
    if (outcome === 'invalid') return { state: 'signed_out' };
    if (outcome === 'retry') return { state: 'unavailable' };
    return await fetchStatus();
  } catch {
    return { state: 'unavailable' };
  }
}

async function fetchStatus(): Promise<WebSessionRestore> {
  const response = await fetch(`${base}/status`, { credentials: 'same-origin' });
  if (response.ok) {
    const status = await response.json().catch(() => null) as WebSessionStatus | null;
    return status?.authenticated === true && status.user_id
      ? { state: 'authenticated', status }
      : { state: 'unavailable' };
  }
  return response.status === 401 ? { state: 'signed_out' } : { state: 'unavailable' };
}

export async function logoutWebSession(): Promise<void> {
  const response = await fetch(`${base}/logout`, {
    method: 'POST', headers: webCSRFHeaders(), credentials: 'same-origin',
  });
  if (!response.ok) throw new Error('Could not sign out this browser session');
}
