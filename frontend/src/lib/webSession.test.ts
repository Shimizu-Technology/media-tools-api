import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  classifyRenewalFailure,
  getSessionPhase,
  isConnectionDegraded,
  isWebOnboardingRequired,
  isWebSessionActive,
  renewWebSession,
  resetWebSessionState,
  restoreWebSession,
  setConnectionDegraded,
  setSessionPhase,
  setWebOnboardingRequired,
  setWebSessionActive,
} from './webSession';

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });
const empty = (status: number) => new Response(null, { status });

function stubCookies(cookie: string) {
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { cookie } });
}

beforeEach(() => {
  vi.restoreAllMocks();
  stubCookies('mta_web_csrf=csrf-token');
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { dispatchEvent: vi.fn() } });
  resetWebSessionState();
});

const urls = (fetchMock: ReturnType<typeof vi.fn>) => fetchMock.mock.calls.map(([url]) => String(url).replace('/api/v1/auth/web/session', ''));

describe('restoring the browser session', () => {
  it('reports an authenticated session from the status route', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ authenticated: true, user_id: 'user-1', onboarding_required: false })));
    await expect(restoreWebSession()).resolves.toEqual({ state: 'authenticated', status: { authenticated: true, user_id: 'user-1', onboarding_required: false } });
  });

  it('renews an expired access cookie and then reports the session', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(json({ authenticated: false }, 401))
      .mockResolvedValueOnce(empty(204))
      .mockResolvedValueOnce(json({ user_id: 'user-1' }))
      .mockResolvedValueOnce(json({ authenticated: true, user_id: 'user-1' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(restoreWebSession()).resolves.toMatchObject({ state: 'authenticated' });
    expect(urls(fetchMock)).toEqual(['/status', '/prepare', '/refresh', '/status']);
  });

  it('is signed out only when the server says the session is invalid', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(json({ authenticated: false }, 401))
      .mockResolvedValueOnce(json({ error: 'invalid_session' }, 401));
    vi.stubGlobal('fetch', fetchMock);
    await expect(restoreWebSession()).resolves.toEqual({ state: 'signed_out' });
  });

  it('is signed out when this browser never had a session (no CSRF cookie, no network call to renew)', async () => {
    stubCookies('');
    const fetchMock = vi.fn().mockResolvedValueOnce(json({ authenticated: false }, 401));
    vi.stubGlobal('fetch', fetchMock);
    await expect(restoreWebSession()).resolves.toEqual({ state: 'signed_out' });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it.each([500, 502, 503, 504, 429, 403, 404])('keeps the session unknown, not signed out, when status answers %i', async (status) => {
    const fetchMock = vi.fn().mockResolvedValue(json({ error: 'x' }, status));
    vi.stubGlobal('fetch', fetchMock);
    await expect(restoreWebSession()).resolves.toEqual({ state: 'unavailable' });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('keeps the session unknown when the network is down', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')));
    await expect(restoreWebSession()).resolves.toEqual({ state: 'unavailable' });
  });

  it('keeps the session unknown when renewal hits a server error', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(json({ authenticated: false }, 401))
      .mockResolvedValueOnce(json({ error: 'authentication_unavailable' }, 503));
    vi.stubGlobal('fetch', fetchMock);
    await expect(restoreWebSession()).resolves.toEqual({ state: 'unavailable' });
  });

  it('keeps the session unknown when renewal loses its connection', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(json({ authenticated: false }, 401))
      .mockRejectedValueOnce(new TypeError('Failed to fetch'));
    vi.stubGlobal('fetch', fetchMock);
    await expect(restoreWebSession()).resolves.toEqual({ state: 'unavailable' });
  });

  it('treats an unreadable success body as unknown, not as signed out', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('<html>proxy error</html>', { status: 200 })));
    await expect(restoreWebSession()).resolves.toEqual({ state: 'unavailable' });
  });
});

describe('renewing the browser session', () => {
  it('signs out only on a 401 from prepare or refresh', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(json({ error: 'invalid_session' }, 401)));
    await expect(renewWebSession()).resolves.toBe('invalid');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(empty(204)).mockResolvedValueOnce(json({ error: 'invalid_session' }, 401)));
    await expect(renewWebSession()).resolves.toBe('invalid');
  });

  it.each([
    ['a CSRF or Origin refusal', 403],
    ['throttling', 429],
    ['a server error', 500],
    ['a bad gateway', 502],
    ['an unavailable renewal', 503],
    ['a missing route', 404],
  ])('keeps the session on %s from prepare', async (_label, status) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(json({ error: 'x' }, status)));
    await expect(renewWebSession()).resolves.toBe('retry');
  });

  it.each([403, 429, 500, 503])('keeps the session when refresh answers %i', async (status) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(empty(204)).mockResolvedValueOnce(json({ error: 'x' }, status)));
    await expect(renewWebSession()).resolves.toBe('retry');
  });

  it('keeps the session when the connection drops mid-renewal', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')));
    await expect(renewWebSession()).resolves.toBe('retry');
  });

  it('prepares again once after a stale pending successor', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(empty(204))
      .mockResolvedValueOnce(json({ error: 'invalid_request' }, 400))
      .mockResolvedValueOnce(empty(204))
      .mockResolvedValueOnce(json({ user_id: 'user-1' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(renewWebSession()).resolves.toBe('renewed');
    expect(urls(fetchMock)).toEqual(['/prepare', '/refresh', '/prepare', '/refresh']);
  });

  it('does not treat a pending successor that stays stale as an invalid session', async () => {
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce(empty(204)).mockResolvedValueOnce(json({ error: 'refresh_not_prepared' }, 400))
      .mockResolvedValueOnce(empty(204)).mockResolvedValueOnce(json({ error: 'invalid_request' }, 400)));
    await expect(renewWebSession()).resolves.toBe('retry');
  });

  it('shares one renewal between concurrent callers', async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(empty(204)).mockResolvedValueOnce(json({ user_id: 'user-1' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(Promise.all([renewWebSession(), renewWebSession()])).resolves.toEqual(['renewed', 'renewed']);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('classifies only 401 as invalid', () => {
    expect(classifyRenewalFailure(empty(401))).toBe('invalid');
    for (const status of [400, 403, 404, 409, 429, 500, 503]) expect(classifyRenewalFailure(empty(status))).toBe('retry');
  });
});

describe('session state', () => {
  it('starts checking and is active only when authenticated', () => {
    expect(getSessionPhase()).toBe('checking');
    expect(isWebSessionActive()).toBe(false);
    setWebSessionActive(true);
    expect(isWebSessionActive()).toBe(true);
    setSessionPhase('unavailable');
    expect(isWebSessionActive()).toBe(false);
  });

  it('clears the onboarding requirement when the session ends', () => {
    setWebSessionActive(true);
    setWebOnboardingRequired(true);
    expect(isWebOnboardingRequired()).toBe(true);
    setWebSessionActive(false);
    expect(isWebOnboardingRequired()).toBe(false);
  });

  it('a degraded connection never changes the session phase', () => {
    setWebSessionActive(true);
    setConnectionDegraded(true);
    expect(isConnectionDegraded()).toBe(true);
    expect(getSessionPhase()).toBe('authenticated');
    setConnectionDegraded(false);
    expect(isConnectionDegraded()).toBe(false);
  });

  it('clears the degraded flag on sign-in and sign-out but keeps it through unavailable', () => {
    setConnectionDegraded(true);
    setSessionPhase('unavailable');
    expect(isConnectionDegraded()).toBe(true);
    setWebSessionActive(true);
    expect(isConnectionDegraded()).toBe(false);
    setConnectionDegraded(true);
    setWebSessionActive(false);
    expect(isConnectionDegraded()).toBe(false);
  });
});
