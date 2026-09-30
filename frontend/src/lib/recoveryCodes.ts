import { renewWebSession, setWebOnboardingRequired, setWebSessionActive, webCSRFHeaders, type WebSessionStatus } from './webSession';

type RecoveryStatus = { remaining: number };
export type RecoveryRotation = { rotation_id: string; codes: string[] };

const webRecoveryBase = '/api/v1/auth/web/session/recovery';
const recoveryBase = '/api/v1/auth/recovery';
let signInRequest: Promise<void> | null = null;

export class RecoveryCodeError extends Error {
  readonly code: string;
  constructor(message: string, code = 'recovery_error') {
    super(message);
    this.name = 'RecoveryCodeError';
    this.code = code;
  }
}

export async function prepareRecoveryCodeSignIn(): Promise<boolean> {
  await prepareRecoverySuccessor();
  const recovery = await tryRecoverPendingRecoverySignIn();
  if (recovery === 'recovered') return true;
  if (recovery === 'stale') await prepareRecoverySuccessor();
  return false;
}

async function prepareRecoverySuccessor(): Promise<void> {
  await requestJSON(`${webRecoveryBase}/prepare`, {
    method: 'POST', credentials: 'same-origin',
  });
}

export function signInWithRecoveryCode(code: string): Promise<void> {
  if (signInRequest) return signInRequest;
  signInRequest = performRecoveryCodeSignIn(code).finally(() => { signInRequest = null; });
  return signInRequest;
}

async function performRecoveryCodeSignIn(code: string): Promise<void> {
  const normalized = code.trim();
  if (!normalized) throw new RecoveryCodeError('Enter one of your saved recovery codes.', 'invalid_recovery_code');
  try {
    await finishRecoveryCodeSignIn({ code: normalized });
  } catch (error) {
    if (!(error instanceof RecoveryCodeError) || error.code !== 'sign_in_not_prepared') throw error;
    // The pending HttpOnly successor may expire while the form is open, or
    // may already belong to an unrecoverable issuance. The failed transaction
    // leaves this code unused, so prepare once and retry this in-memory value.
    await prepareRecoverySuccessor();
    await finishRecoveryCodeSignIn({ code: normalized });
  }
}

export async function recoverPendingRecoverySignIn(): Promise<boolean> {
  return (await tryRecoverPendingRecoverySignIn()) === 'recovered';
}

async function tryRecoverPendingRecoverySignIn(): Promise<'recovered' | 'none' | 'stale'> {
  try {
    await finishRecoveryCodeSignIn({});
    return 'recovered';
  } catch (error) {
    if (error instanceof RecoveryCodeError && error.code === 'invalid_recovery_code') return 'none';
    if (error instanceof RecoveryCodeError && error.code === 'sign_in_not_prepared') return 'stale';
    throw error;
  }
}

async function finishRecoveryCodeSignIn(body: { code?: string }): Promise<void> {
  const execute = () => fetch(`${webRecoveryBase}/finish`, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...webCSRFHeaders() },
    body: JSON.stringify(body),
  });
  let response: Response;
  try {
    response = await execute();
  } catch {
    try { response = await execute(); } catch { throw new RecoveryCodeError('Could not reach Media Tools. Check your connection and try again.', 'network_error'); }
  }
  if (response.status >= 500) response = await execute().catch(() => response);
  if (!response.ok) throw await responseError(response, 'Could not complete recovery sign-in.');
  const metadata = await response.json() as Record<string, unknown>;
  if ('access_token' in metadata || 'refresh_token' in metadata) {
    throw new RecoveryCodeError('Recovery sign-in returned an unsafe response.', 'unsafe_response');
  }
  const status = await requestJSON<WebSessionStatus>('/api/v1/auth/web/session/status', { credentials: 'same-origin' });
  if (!status.authenticated) throw new RecoveryCodeError('Could not verify the recovered session.', 'authentication_unavailable');
  setWebOnboardingRequired(status.onboarding_required === true);
  setWebSessionActive(true);
}

export async function getRecoveryCodeStatus(): Promise<RecoveryStatus> {
  const status = await authenticatedRequestJSON<RecoveryStatus>(recoveryBase, { credentials: 'same-origin' });
  return { remaining: Number.isInteger(status.remaining) && status.remaining >= 0 ? status.remaining : 0 };
}

export async function beginRecoveryCodeRotation(): Promise<RecoveryRotation> {
  const rotation = await authenticatedRequestJSON<RecoveryRotation>(`${recoveryBase}/rotation/begin`, {
    method: 'POST', credentials: 'same-origin', headers: webCSRFHeaders(),
  });
  if (!rotation.rotation_id || !Array.isArray(rotation.codes) || rotation.codes.length === 0 || rotation.codes.some((code) => typeof code !== 'string')) {
    throw new RecoveryCodeError('The server returned an invalid recovery-code set.', 'invalid_response');
  }
  return rotation;
}

export async function confirmRecoveryCodeRotation(rotationID: string): Promise<number> {
  const status = await authenticatedRequestJSON<RecoveryStatus>(`${recoveryBase}/rotation/confirm`, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...webCSRFHeaders() },
    body: JSON.stringify({ rotation_id: rotationID }),
  });
  return Number.isInteger(status.remaining) && status.remaining >= 0 ? status.remaining : 0;
}

async function authenticatedRequestJSON<T>(url: string, init: RequestInit): Promise<T> {
  let response = await safeFetch(url, init);
  if (response.status === 401) {
    const body = await response.clone().json().catch(() => null) as { error?: string } | null;
    if (body?.error === 'unauthorized') {
      const renewal = await renewWebSession();
      if (renewal === 'renewed') {
        const headers = Object.fromEntries(new Headers(init.headers));
        response = await safeFetch(url, { ...init, headers: { ...headers, ...webCSRFHeaders() } });
      } else if (renewal === 'invalid') {
        setWebSessionActive(false);
      } else {
        throw new RecoveryCodeError('Could not renew your session. Please try again.', 'authentication_unavailable');
      }
    }
  }
  if (!response.ok) throw await responseError(response, 'Recovery-code request failed.');
  return await response.json() as T;
}

async function requestJSON<T = Record<string, unknown>>(url: string, init: RequestInit): Promise<T> {
  const response = await safeFetch(url, init);
  if (!response.ok) throw await responseError(response, 'Recovery-code request failed.');
  if (response.status === 204) return {} as T;
  return await response.json() as T;
}

async function safeFetch(url: string, init: RequestInit): Promise<Response> {
  try { return await fetch(url, init); }
  catch { throw new RecoveryCodeError('Could not reach Media Tools. Check your connection and try again.', 'network_error'); }
}

async function responseError(response: Response, fallback: string): Promise<RecoveryCodeError> {
  const body = await response.json().catch(() => null) as { error?: string; message?: string } | null;
  return new RecoveryCodeError(body?.message || fallback, body?.error || 'recovery_error');
}
