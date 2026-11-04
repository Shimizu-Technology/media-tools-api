/**
 * Email and password account API (docs/AUTH_API.md).
 *
 * Signed-out initiation routes always answer 202 with the same body, so this
 * module never reports whether an address has an account. Codes are used once
 * and live only in component state: they are never written to storage or URLs.
 */
import { fetchWithAuth } from './api';
import { webCSRFHeaders } from './webSession';

const base = '/api/v1/auth';

export class AccountAuthError extends Error {
  /** Stable machine-readable identifier from the API, or a client-side code. */
  readonly code: string;
  readonly status: number;
  readonly retryAfterSeconds?: number;
  constructor(message: string, code: string, status = 0, retryAfterSeconds?: number) {
    super(message);
    this.name = 'AccountAuthError';
    this.code = code;
    this.status = status;
    this.retryAfterSeconds = retryAfterSeconds;
  }
  /** True when the request may succeed unchanged later; the session is intact. */
  get retryable(): boolean {
    return this.status === 0 || this.status === 429 || this.status >= 500;
  }
}

export const NETWORK_MESSAGE = 'Could not reach Media Tools. Check your connection and try again.';

const friendly: Record<string, string> = {
  weak_password: 'Use a password of 12 to 128 characters.',
  password_compromised: 'That password has appeared in a data breach. Choose a different one.',
  invalid_code: 'That code is not valid or has expired. Request a new one.',
  invalid_credentials: 'Email or password is incorrect.',
  current_password_required: 'Enter your current password.',
  email_verification_required: 'Verify your email first.',
  signup_disabled: 'Creating accounts is not available yet.',
  credential_changed: 'Your sign-in details changed. Sign in again to continue.',
  password_required: 'Create a password before changing your email.',
  monthly_transcription_cap: 'You have used this month’s transcription minutes.',
  monthly_ai_cap: 'You have used this month’s summary and chat requests.',
};

export async function toAccountAuthError(response: Response, fallback: string): Promise<AccountAuthError> {
  const body = await response.json().catch(() => null) as { error?: string; message?: string } | null;
  const code = body?.error || 'request_failed';
  const retryAfter = Number.parseInt(response.headers.get('Retry-After') || '', 10);
  let message = friendly[code] || body?.message || fallback;
  if (response.status === 429) {
    message = Number.isFinite(retryAfter) && retryAfter > 0
      ? `Too many attempts. Try again in ${formatWait(retryAfter)}.`
      : 'Too many attempts. Wait a moment and try again.';
  } else if (response.status >= 500) {
    message = 'Media Tools is having trouble right now. Try again in a moment.';
  }
  return new AccountAuthError(message, code, response.status, Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : undefined);
}

function formatWait(seconds: number): string {
  if (seconds < 90) return `${seconds} seconds`;
  return `${Math.ceil(seconds / 60)} minutes`;
}

async function post(path: string, body: unknown, signedIn: boolean): Promise<Response> {
  const init: RequestInit = {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...webCSRFHeaders() },
    body: JSON.stringify(body),
  };
  try {
    return signedIn ? await fetchWithAuth(`${base}${path}`, init) : await fetch(`${base}${path}`, init);
  } catch {
    throw new AccountAuthError(NETWORK_MESSAGE, 'network_error');
  }
}

async function expectOk(response: Response, fallback: string): Promise<void> {
  if (!response.ok) throw await toAccountAuthError(response, fallback);
}

/** Step one of sign-up. Resolves for every address, eligible or not. */
export async function startSignup(email: string, name: string): Promise<void> {
  await expectOk(await post('/signup', name.trim() ? { email: email.trim(), name: name.trim() } : { email: email.trim() }, false), 'Could not start sign-up.');
}

/** Step two: the emailed code proves the address and sets the first password. */
export async function verifySignup(email: string, code: string, password: string): Promise<void> {
  await expectOk(await post('/signup/verify', { email: email.trim(), code: code.trim(), password }, false), 'Could not finish sign-up.');
}

export async function startPasswordReset(email: string): Promise<void> {
  await expectOk(await post('/password/forgot', { email: email.trim() }, false), 'Could not start the password reset.');
}

/** Success verifies the email, sets the password and revokes every device. */
export async function finishPasswordReset(email: string, code: string, password: string): Promise<void> {
  await expectOk(await post('/password/reset', { email: email.trim(), code: code.trim(), password }, false), 'Could not reset the password.');
}

export async function startEmailVerification(email: string): Promise<void> {
  await expectOk(await post('/email/verify', { email: email.trim() }, true), 'Could not send a code.');
}

export async function confirmEmailVerification(email: string, code: string): Promise<void> {
  await expectOk(await post('/email/verify/confirm', { email: email.trim(), code: code.trim() }, true), 'Could not verify the email.');
}

export async function startEmailChange(newEmail: string, currentPassword: string): Promise<void> {
  await expectOk(await post('/email/change', { email: newEmail.trim(), current_password: currentPassword }, true), 'Could not start the email change.');
}

/** Success changes the email and revokes every session, including this one. */
export async function finishEmailChange(newEmail: string, code: string): Promise<void> {
  await expectOk(await post('/email/change/verify', { email: newEmail.trim(), code: code.trim() }, true), 'Could not change the email.');
}

export async function changePassword(password: string, currentPassword?: string): Promise<void> {
  await expectOk(await post('/password', currentPassword ? { password, current_password: currentPassword } : { password }, true), 'Could not save the password.');
}

export type PasswordStatus = { configured: boolean; updated_at?: string };

export async function getPasswordStatus(): Promise<PasswordStatus> {
  return getJSON<PasswordStatus>('/password', 'Could not check your password.');
}

export type Usage = {
  month: string;
  transcription_seconds: number;
  transcription_limit_seconds: number;
  ai_requests: number;
  ai_request_limit: number;
  exempt: boolean;
};

export async function getUsage(): Promise<Usage> {
  return getJSON<Usage>('/usage', 'Could not load your usage.');
}

export type DeviceSession = {
  id: string;
  client_type: string;
  device_name: string;
  created_at: string;
  last_used_at: string;
  inactive_expires_at: string;
  revoked_at?: string | null;
};

export async function listDevices(): Promise<DeviceSession[]> {
  const result = await getJSON<{ sessions: DeviceSession[] | null }>('/sessions', 'Could not load your devices.');
  return (result.sessions ?? []).filter((session) => !session.revoked_at);
}

export async function revokeDevice(id: string): Promise<void> {
  try {
    const response = await fetchWithAuth(`${base}/sessions/${encodeURIComponent(id)}`, {
      method: 'DELETE', credentials: 'same-origin', headers: webCSRFHeaders(),
    });
    // Already gone is the outcome the user asked for.
    if (response.status === 404) return;
    await expectOk(response, 'Could not sign that device out.');
  } catch (error) {
    if (error instanceof AccountAuthError) throw error;
    throw new AccountAuthError(NETWORK_MESSAGE, 'network_error');
  }
}

async function getJSON<T>(path: string, fallback: string): Promise<T> {
  let response: Response;
  try {
    response = await fetchWithAuth(`${base}${path}`, { credentials: 'same-origin', cache: 'no-store' });
  } catch {
    throw new AccountAuthError(NETWORK_MESSAGE, 'network_error');
  }
  if (!response.ok) throw await toAccountAuthError(response, fallback);
  return await response.json() as T;
}

/** Minutes shown to people; the API reports seconds. */
export function secondsToMinutes(seconds: number): number {
  return Math.ceil(Math.max(0, seconds) / 60);
}

export function usageFraction(used: number, limit: number): number {
  if (limit <= 0) return 0;
  return Math.min(1, Math.max(0, used / limit));
}

/** First day of next month in UTC, when the monthly counters reset. */
export function nextUsageReset(month: string): Date | null {
  const start = new Date(month);
  if (Number.isNaN(start.getTime())) return null;
  return new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 1));
}
