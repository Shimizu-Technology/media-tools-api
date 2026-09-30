/** Same-origin browser session. The refresh credential never enters JavaScript. */
export const webSessionEnabled = import.meta.env.VITE_WEB_COOKIE_AUTH_ENABLED === 'true';
let active = false;
export function isWebSessionActive(): boolean { return webSessionEnabled && active; }
export function setWebSessionActive(value: boolean): void { active = value; }

const base = '/api/v1/auth/web/session';
let renewal: Promise<boolean> | null = null;
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

export async function renewWebSession(): Promise<boolean> {
  if (renewal) return renewal;
  renewal = (async () => {
    const headers = webCSRFHeaders();
    if (!headers['X-CSRF-Token']) return false;
    const prepare = await fetch(`${base}/prepare`, { method: 'POST', headers, credentials: 'same-origin' });
    if (!prepare.ok) return false;
    const refresh = await fetch(`${base}/refresh`, { method: 'POST', headers, credentials: 'same-origin' });
    return refresh.ok;
  })().catch(() => false).finally(() => { renewal = null; });
  return renewal;
}

export async function restoreWebSession(): Promise<string | null> {
  try {
    const status = await fetch(`${base}/status`, { credentials: 'same-origin' });
    if (status.ok) return restoredClerkID(await status.json() as WebSessionStatus);
    if (!await renewWebSession()) return null;
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
