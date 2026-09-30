import { renewWebSession, restoreWebSession, setWebOnboardingRequired, setWebSessionActive, webCSRFHeaders } from './webSession';

export type JoinKind = 'invite' | 'onboarding';

export type JoinTransferResult =
  | { state: 'none' }
  | { state: 'transferred'; kind: JoinKind }
  | { state: 'failed'; message: string };

export type WebOnboardingStatus = {
  pending: boolean;
  kind: JoinKind | '';
  session_ready: boolean;
  onboarding_required: boolean;
  passkeys: number;
  recovery_codes: number;
  complete: boolean;
};

const base = '/api/v1/auth/web/session/onboarding';
let commitRequest: Promise<WebOnboardingStatus> | null = null;

/**
 * Runs before Clerk, auth restoration, analytics, or any other app network
 * work. The URL fragment stays in history unless the server confirms it was
 * installed in the narrow HttpOnly onboarding cookie.
 */
export async function transferJoinFragmentBeforeApp(): Promise<JoinTransferResult> {
  if (!isJoinSetupPath(window.location.pathname) || !window.location.hash) return { state: 'none' };
  const parsed = parseJoinFragment(window.location.hash);
  if (!parsed) return { state: 'failed', message: 'This setup link is invalid or incomplete.' };
  let response: Response;
  try {
    response = await fetch(`${base}/transfer`, {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(parsed),
    });
  } catch {
    return { state: 'failed', message: 'Could not reach Media Tools. Check your connection and try again.' };
  }
  if (!response.ok) {
    const error = await response.json().catch(() => null) as { message?: string } | null;
    return { state: 'failed', message: error?.message || 'Could not secure this setup link. Try again.' };
  }
  window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}`);
  return { state: 'transferred', kind: parsed.kind };
}

export function isJoinSetupPath(pathname: string): boolean {
  return pathname === '/join' || pathname === '/join/';
}

export function parseJoinFragment(hash: string): { kind: JoinKind; token: string } | null {
  const params = new URLSearchParams(hash.startsWith('#') ? hash.slice(1) : hash);
  const entries = [...params.entries()];
  if (entries.length !== 1) return null;
  const [key, token] = entries[0];
  const kind = key === 'invite' ? 'invite' : key === 'onboarding' ? 'onboarding' : null;
  if (!kind || !validTokenShape(kind, token)) return null;
  return { kind, token };
}

export async function getWebOnboardingStatus(): Promise<WebOnboardingStatus> {
  let status = await fetchOnboardingStatus();
  if (!status.pending && !status.session_ready) {
    // An interrupted setup can outlive its short access cookie. Restore from
    // the year-long HttpOnly refresh cookie before deciding the link is gone.
    const restored = await restoreWebSession();
    if (restored?.authenticated) status = await fetchOnboardingStatus();
  }
  return status;
}

async function fetchOnboardingStatus(): Promise<WebOnboardingStatus> {
  const response = await safeFetch(`${base}/status`, { credentials: 'same-origin' });
  if (!response.ok) throw await responseError(response, 'Could not check account setup.');
  return normalizeStatus(await response.json() as Partial<WebOnboardingStatus>);
}

export function commitWebOnboarding(): Promise<WebOnboardingStatus> {
  if (commitRequest) return commitRequest;
  commitRequest = performCommit().finally(() => { commitRequest = null; });
  return commitRequest;
}

async function performCommit(): Promise<WebOnboardingStatus> {
  try {
    await finishCommit();
  } catch (error) {
    if (!(error instanceof OnboardingError) || error.code !== 'onboarding_not_prepared') throw error;
    await prepareCommit();
    await finishCommit();
  }
  const restored = await restoreWebSession();
  if (!restored?.authenticated || !restored.onboarding_required) {
    throw new OnboardingError('Could not verify the new browser session.', 'authentication_unavailable');
  }
  setWebSessionActive(true);
  setWebOnboardingRequired(true);
  return await getWebOnboardingStatus();
}

async function finishCommit(): Promise<void> {
  const execute = () => fetch(`${base}/commit`, {
    method: 'POST', credentials: 'same-origin', headers: webCSRFHeaders(),
  });
  let response: Response;
  try {
    response = await execute();
  } catch {
    try { response = await execute(); }
    catch {
      if (await committedSessionExists()) return;
      throw new OnboardingError('Could not reach Media Tools. Check your connection and try again.', 'network_error');
    }
  }
  if (response.status >= 500) {
    response = await execute().catch(() => response);
  }
  if (!response.ok) {
    if (response.status >= 500 && await committedSessionExists()) return;
    throw await responseError(response, 'Could not create the browser session.');
  }
  const metadata = await response.json() as Record<string, unknown>;
  if ('access_token' in metadata || 'refresh_token' in metadata) {
    throw new OnboardingError('Account setup returned an unsafe response.', 'unsafe_response');
  }
}

async function committedSessionExists(): Promise<boolean> {
  const restored = await restoreWebSession().catch(() => null);
  if (!restored?.authenticated || !restored.onboarding_required) return false;
  setWebSessionActive(true);
  setWebOnboardingRequired(true);
  return true;
}

async function prepareCommit(): Promise<void> {
  const response = await safeFetch(`${base}/prepare`, { method: 'POST', credentials: 'same-origin' });
  if (!response.ok) throw await responseError(response, 'Could not prepare account setup.');
}

export async function completeWebOnboarding(): Promise<void> {
  let response = await safeFetch(`${base}/complete`, {
    method: 'POST', credentials: 'same-origin', headers: webCSRFHeaders(),
  });
  if (response.status === 401) {
    const renewal = await renewWebSession();
    if (renewal === 'renewed') {
      response = await safeFetch(`${base}/complete`, {
        method: 'POST', credentials: 'same-origin', headers: webCSRFHeaders(),
      });
    }
  }
  if (!response.ok) throw await responseError(response, 'Could not finish account setup.');
  setWebOnboardingRequired(false);
}

export class OnboardingError extends Error {
  readonly code: string;
  constructor(message: string, code = 'onboarding_error') {
    super(message);
    this.name = 'OnboardingError';
    this.code = code;
  }
}

function validTokenShape(kind: JoinKind, token: string): boolean {
  const prefix = kind === 'invite' ? 'mta_inv_' : 'mta_onb_';
  return token.startsWith(prefix) && token.length === prefix.length + 43 && /^[A-Za-z0-9_-]+$/.test(token.slice(prefix.length));
}

function normalizeStatus(status: Partial<WebOnboardingStatus>): WebOnboardingStatus {
  const kind = status.kind === 'invite' || status.kind === 'onboarding' ? status.kind : '';
  const passkeys = Number.isInteger(status.passkeys) && Number(status.passkeys) >= 0 ? Number(status.passkeys) : 0;
  const recoveryCodes = Number.isInteger(status.recovery_codes) && Number(status.recovery_codes) >= 0 ? Number(status.recovery_codes) : 0;
  return {
    pending: status.pending === true,
    kind,
    session_ready: status.session_ready === true,
    onboarding_required: status.onboarding_required === true,
    passkeys,
    recovery_codes: recoveryCodes,
    complete: status.complete === true && passkeys > 0 && recoveryCodes > 0,
  };
}

async function safeFetch(url: string, init: RequestInit): Promise<Response> {
  try { return await fetch(url, init); }
  catch { throw new OnboardingError('Could not reach Media Tools. Check your connection and try again.', 'network_error'); }
}

async function responseError(response: Response, fallback: string): Promise<OnboardingError> {
  const body = await response.json().catch(() => null) as { error?: string; message?: string } | null;
  return new OnboardingError(body?.message || fallback, body?.error || 'onboarding_error');
}
