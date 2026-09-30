/** Same-origin browser session. The refresh credential never enters JavaScript. */
export const webSessionEnabled = import.meta.env.VITE_WEB_COOKIE_AUTH_ENABLED === 'true';
let active = false;
export const webSessionStateChanged = 'mta:web-session-state-changed';
export function isWebSessionActive(): boolean { return webSessionEnabled && active; }
export function setWebSessionActive(value: boolean): void {
  if (active === value) return;
  active = value;
  window.dispatchEvent(new CustomEvent(webSessionStateChanged, { detail: { active: isWebSessionActive() } }));
}

const base = '/api/v1/auth/web/session';
export type WebSessionRenewal = 'renewed' | 'invalid' | 'retry';
let renewal: Promise<WebSessionRenewal> | null = null;
export type WebSessionStatus = { authenticated: true; user_id: string; clerk_id?: string | null };

export function webSessionConflictsWithClerk(status: WebSessionStatus, clerkUserID: string | null): boolean {
  return Boolean(clerkUserID && status.clerk_id !== clerkUserID);
}

export async function reconcileWebSessionWithClerk(
  status: WebSessionStatus | null,
  clerkUserID: string | null,
  revoke: () => Promise<void> = logoutWebSession,
): Promise<WebSessionStatus | null> {
  if (!status || !webSessionConflictsWithClerk(status, clerkUserID)) return status;
  await revoke();
  return null;
}

function csrfToken(): string {
  const value = document.cookie.split('; ').find((part) => part.startsWith('mta_web_csrf='));
  return value ? decodeURIComponent(value.slice('mta_web_csrf='.length)) : '';
}

export function webCSRFHeaders(): Record<string, string> {
  const token = csrfToken();
  return token ? { 'X-CSRF-Token': token } : {};
}

export async function bootstrapWebSession(clerkToken: string, expectedClerkID: string): Promise<boolean> {
  try {
    const prepared = await fetch(`${base}/bootstrap/prepare`, { method: 'POST', credentials: 'same-origin' });
    if (!prepared.ok) return false;
    const commit = () => fetch(`${base}/bootstrap`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${clerkToken}`, ...webCSRFHeaders() },
      credentials: 'same-origin',
    });
    let response: Response;
    try { response = await commit(); } catch { response = await commit(); }
    // The successor cookie makes an identical retry safe: the server recovers
    // the first session and only replaces its short-lived access credential.
    if (!response.ok && response.status >= 500) response = await commit();
    if (response.ok) {
      const result = await response.json().catch(() => null) as WebSessionStatus | null;
      if (result?.clerk_id === expectedClerkID) return true;
      await logoutWebSession().catch(() => undefined);
      return false;
    }
    return await statusMatchesClerk(expectedClerkID);
  } catch {
    return await statusMatchesClerk(expectedClerkID);
  }
}

async function statusMatchesClerk(expectedClerkID: string): Promise<boolean> {
  try {
    const status = await fetch(`${base}/status`, { credentials: 'same-origin' });
    if (!status.ok) return false;
    const restored = (await status.json()) as WebSessionStatus;
    if (restored.clerk_id === expectedClerkID) return true;
    // A response-loss probe must never leave another account's cookie active
    // beside the currently verified Clerk subject.
    await logoutWebSession().catch(() => undefined);
    return false;
  } catch { return false; }
}

export async function renewWebSession(): Promise<WebSessionRenewal> {
  if (renewal) return renewal;
  renewal = (async (): Promise<WebSessionRenewal> => {
    const headers = webCSRFHeaders();
    if (!headers['X-CSRF-Token']) return 'invalid';
    const first = await prepareAndRefresh(headers);
    if (first === 'invalid_pending') {
      const second = await prepareAndRefresh(headers);
      return second === 'invalid_pending' ? 'invalid' : second;
    }
    return first;
  })().catch(() => 'retry' as const).finally(() => { renewal = null; });
  return renewal;
}

type PreparedRefreshResult = WebSessionRenewal | 'invalid_pending';

async function prepareAndRefresh(headers: Record<string, string>): Promise<PreparedRefreshResult> {
  const prepare = await fetch(`${base}/prepare`, { method: 'POST', headers, credentials: 'same-origin' });
  if (!prepare.ok) return classifyRenewalFailure(prepare);
  const refresh = await fetch(`${base}/refresh`, { method: 'POST', headers, credentials: 'same-origin' });
  if (refresh.ok) return 'renewed';
  if (await isInvalidPendingRefresh(refresh)) return 'invalid_pending';
  return classifyRenewalFailure(refresh);
}

async function isInvalidPendingRefresh(response: Response): Promise<boolean> {
  if (response.status !== 400) return false;
  const body = await response.clone().json().catch(() => null) as { error?: string } | null;
  return body?.error === 'invalid_request';
}

function classifyRenewalFailure(response: Response): WebSessionRenewal {
  if (response.status >= 500) return 'retry';
  return 'invalid';
}

export async function restoreWebSession(): Promise<WebSessionStatus | null> {
  try {
    const status = await fetch(`${base}/status`, { credentials: 'same-origin' });
    if (status.ok) return await status.json() as WebSessionStatus;
    if (await renewWebSession() !== 'renewed') return null;
    const renewed = await fetch(`${base}/status`, { credentials: 'same-origin' });
    return renewed.ok ? await renewed.json() as WebSessionStatus : null;
  } catch {
    return null;
  }
}

export async function logoutWebSession(): Promise<void> {
  const response = await fetch(`${base}/logout`, {
    method: 'POST', headers: webCSRFHeaders(), credentials: 'same-origin',
  });
  if (!response.ok) throw new Error('Could not sign out this browser session');
}
