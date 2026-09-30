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
type WebSessionStatus = { clerk_id?: string | null };

function csrfToken(): string {
  const value = document.cookie.split('; ').find((part) => part.startsWith('mta_web_csrf='));
  return value ? decodeURIComponent(value.slice('mta_web_csrf='.length)) : '';
}

export function webCSRFHeaders(): Record<string, string> {
  const token = csrfToken();
  return token ? { 'X-CSRF-Token': token } : {};
}

export async function bootstrapWebSession(clerkToken: string): Promise<boolean> {
  const res = await fetch(`${base}/bootstrap`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${clerkToken}` },
    credentials: 'same-origin',
  });
  return res.ok;
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

export async function restoreWebSession(): Promise<string | null> {
  try {
    const status = await fetch(`${base}/status`, { credentials: 'same-origin' });
    if (status.ok) return restoredClerkID(await status.json() as WebSessionStatus);
    if (await renewWebSession() !== 'renewed') return null;
    const renewed = await fetch(`${base}/status`, { credentials: 'same-origin' });
    return renewed.ok ? restoredClerkID(await renewed.json() as WebSessionStatus) : null;
  } catch {
    return null;
  }
}

function restoredClerkID(status: WebSessionStatus): string {
  return typeof status.clerk_id === 'string' ? status.clerk_id : '';
}

export async function logoutWebSession(): Promise<void> {
  const response = await fetch(`${base}/logout`, {
    method: 'POST', headers: webCSRFHeaders(), credentials: 'same-origin',
  });
  if (!response.ok) throw new Error('Could not sign out this browser session');
}
