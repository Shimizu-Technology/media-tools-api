import { renewWebSession, setWebOnboardingRequired, setWebSessionActive, webCSRFHeaders, type WebSessionStatus } from './webSession';

const webPasswordBase = '/api/v1/auth/web/session/password';
const passwordBase = '/api/v1/auth/password';

export type PasswordStatus = { configured: boolean; updated_at?: string };

export class PasswordError extends Error {
  readonly code: string;
  constructor(message: string, code = 'password_error') {
    super(message);
    this.name = 'PasswordError';
    this.code = code;
  }
}

export async function signInWithPassword(email: string, password: string): Promise<void> {
  const prepared = await safeFetch(`${webPasswordBase}/prepare`, { method: 'POST', credentials: 'same-origin' });
  if (!prepared.ok) throw await responseError(prepared, 'Could not prepare password sign-in.');
  const execute = () => safeFetch(`${webPasswordBase}/finish`, {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...webCSRFHeaders() },
    body: JSON.stringify({ email: email.trim(), password }),
  });
  let response: Response | undefined;
  try {
    response = await execute();
  } catch (error) {
    try { response = await execute(); }
    catch { throw error; }
  }
  if (response.status >= 500) {
    try { response = await execute(); }
    catch {
      throw new PasswordError('Could not reach Media Tools. Check your connection and try again.', 'network_error');
    }
  }
  if (!response.ok) {
    throw await responseError(response, 'Could not sign in.');
  }
  const metadata = await response.json() as Record<string, unknown>;
  if ('access_token' in metadata || 'refresh_token' in metadata) {
    throw new PasswordError('Password sign-in returned an unsafe response.', 'unsafe_response');
  }
  const committedUserID = typeof metadata.user_id === 'string' ? metadata.user_id : '';
  if (metadata.authenticated !== true || !committedUserID || !await committedPasswordSessionExists(committedUserID)) {
    throw new PasswordError('Could not verify the new session.', 'authentication_unavailable');
  }
}

async function committedPasswordSessionExists(expectedUserID: string): Promise<boolean> {
  const status = await safeFetch('/api/v1/auth/web/session/status', { credentials: 'same-origin' }).catch(() => null);
  if (!status?.ok) return false;
  const restored = await status.json().catch(() => null) as WebSessionStatus | null;
  if (!restored?.authenticated || restored.user_id !== expectedUserID) return false;
  setWebOnboardingRequired(restored.onboarding_required === true);
  setWebSessionActive(true);
  return true;
}

export async function getPasswordStatus(): Promise<PasswordStatus> {
  return authenticatedJSON<PasswordStatus>(passwordBase, { credentials: 'same-origin' });
}

export async function setPassword(password: string): Promise<PasswordStatus> {
  return authenticatedJSON<PasswordStatus>(passwordBase, {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...webCSRFHeaders() },
    body: JSON.stringify({ password }),
  });
}

async function authenticatedJSON<T>(url: string, init: RequestInit): Promise<T> {
  let response = await safeFetch(url, init);
  if (response.status === 401 && await errorCode(response) === 'unauthorized') {
    const renewal = await renewWebSession();
    if (renewal === 'renewed') {
      response = await safeFetch(url, { ...init, headers: { ...Object.fromEntries(new Headers(init.headers)), ...webCSRFHeaders() } });
    } else if (renewal === 'invalid') {
      setWebSessionActive(false);
    } else {
      throw new PasswordError('Could not renew your session. Please try again.', 'authentication_unavailable');
    }
  }
  if (!response.ok) throw await responseError(response, 'Password request failed.');
  return await response.json() as T;
}

async function safeFetch(url: string, init: RequestInit): Promise<Response> {
  try { return await fetch(url, init); }
  catch { throw new PasswordError('Could not reach Media Tools. Check your connection and try again.', 'network_error'); }
}

async function errorCode(response: Response): Promise<string | undefined> {
  const body = await response.clone().json().catch(() => null) as { error?: string } | null;
  return body?.error;
}

async function responseError(response: Response, fallback: string): Promise<PasswordError> {
  const body = await response.json().catch(() => null) as { error?: string; message?: string } | null;
  return new PasswordError(body?.message || fallback, body?.error || 'password_error');
}
