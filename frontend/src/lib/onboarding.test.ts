import { beforeEach, describe, expect, it, vi } from 'vitest';

import { commitWebOnboarding, completeWebOnboarding, getWebOnboardingStatus, isJoinSetupPath, parseJoinFragment, transferJoinFragmentBeforeApp } from './onboarding';

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() { return values.size; }, clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null, key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => { values.delete(key); }, setItem: (key, value) => { values.set(key, value); },
  };
}

const inviteToken = `mta_inv_${'A'.repeat(43)}`;

beforeEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: memoryStorage() });
  Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: memoryStorage() });
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { cookie: 'mta_web_csrf=csrf-token' } });
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      location: { pathname: '/join', search: '', hash: `#invite=${inviteToken}` },
      history: { replaceState: vi.fn() },
      dispatchEvent: vi.fn(),
    },
  });
});

describe('join fragment transfer', () => {
  it('accepts exactly one canonical invitation or rescue fragment', () => {
    expect(isJoinSetupPath('/join')).toBe(true);
    expect(isJoinSetupPath('/join/')).toBe(true);
    expect(isJoinSetupPath('/app')).toBe(false);
    expect(parseJoinFragment(`#invite=${inviteToken}`)).toEqual({ kind: 'invite', token: inviteToken });
    expect(parseJoinFragment(`#onboarding=mta_onb_${'z'.repeat(43)}`)).toEqual({ kind: 'onboarding', token: `mta_onb_${'z'.repeat(43)}` });
    expect(parseJoinFragment(`#invite=${inviteToken}&extra=value`)).toBeNull();
    expect(parseJoinFragment('#invite=not-a-token')).toBeNull();
    expect(parseJoinFragment(`#other=${inviteToken}`)).toBeNull();
  });

  it('removes the fragment only after the server confirms HttpOnly transfer', async () => {
    const order: string[] = [];
    const fetchMock = vi.fn(async (...args: Parameters<typeof fetch>) => {
      void args;
      order.push('transfer');
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal('fetch', fetchMock);
    window.history.replaceState = vi.fn(() => { order.push('replace'); });

    await expect(transferJoinFragmentBeforeApp()).resolves.toEqual({ state: 'transferred', kind: 'invite' });
    expect(order).toEqual(['transfer', 'replace']);
    expect(window.history.replaceState).toHaveBeenCalledWith(null, '', '/join');
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body))).toEqual({ kind: 'invite', token: inviteToken });
  });

  it('keeps the secret fragment through transport and server failures', async () => {
    const replace = vi.spyOn(window.history, 'replaceState');
    vi.stubGlobal('fetch', vi.fn().mockRejectedValueOnce(new TypeError('offline')));
    await expect(transferJoinFragmentBeforeApp()).resolves.toMatchObject({ state: 'failed' });
    expect(replace).not.toHaveBeenCalled();
    expect(window.location.hash).toBe(`#invite=${inviteToken}`);

    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response(JSON.stringify({ message: 'Retry safely' }), { status: 503, headers: { 'Content-Type': 'application/json' } })));
    await expect(transferJoinFragmentBeforeApp()).resolves.toEqual({ state: 'failed', message: 'Retry safely' });
    expect(replace).not.toHaveBeenCalled();
  });
});

describe('web onboarding commit', () => {
  it('prepares once and retries the same protected link after a stale successor', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'onboarding_not_prepared', message: 'Prepare again' }), { status: 400, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, onboarding_required: true, user_id: 'user-1' }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, onboarding_required: true, user_id: 'user-1' }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ pending: false, session_ready: true, onboarding_required: true, passkeys: 0, recovery_codes: 0, complete: false }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(commitWebOnboarding()).resolves.toMatchObject({ session_ready: true, onboarding_required: true });
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      '/api/v1/auth/web/session/onboarding/commit',
      '/api/v1/auth/web/session/onboarding/prepare',
      '/api/v1/auth/web/session/onboarding/commit',
      '/api/v1/auth/web/session/status',
      '/api/v1/auth/web/session/onboarding/status',
    ]);
  });

  it('recovers a lost response and never writes secrets to browser storage', async () => {
    const localSet = vi.spyOn(localStorage, 'setItem');
    const sessionSet = vi.spyOn(sessionStorage, 'setItem');
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError('response lost'))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, onboarding_required: true, user_id: 'user-1' }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, onboarding_required: true, user_id: 'user-1' }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ pending: false, session_ready: true, onboarding_required: true, passkeys: 0, recovery_codes: 0, complete: false }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(commitWebOnboarding()).resolves.toMatchObject({ onboarding_required: true });
    expect(fetchMock.mock.calls[1][1]).toEqual(fetchMock.mock.calls[0][1]);
    expect(localSet).not.toHaveBeenCalled();
    expect(sessionSet).not.toHaveBeenCalled();
  });

  it('rejects token-bearing success JSON', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ authenticated: true, access_token: 'secret' }), { status: 201, headers: { 'Content-Type': 'application/json' } })));
    await expect(commitWebOnboarding()).rejects.toMatchObject({ code: 'unsafe_response' });
  });

  it('renews an expired access cookie before server-authoritative completion', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(completeWebOnboarding()).resolves.toBeUndefined();
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      '/api/v1/auth/web/session/onboarding/complete',
      '/api/v1/auth/web/session/prepare',
      '/api/v1/auth/web/session/refresh',
      '/api/v1/auth/web/session/onboarding/complete',
    ]);
  });

  it('renews an expired access cookie before resuming an interrupted setup', async () => {
    const incomplete = { pending: false, session_ready: false, onboarding_required: false, passkeys: 0, recovery_codes: 0, complete: false };
    const resumed = { pending: false, session_ready: true, onboarding_required: true, passkeys: 1, recovery_codes: 0, complete: false };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(incomplete), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: false }), { status: 401, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, onboarding_required: true, user_id: 'user-1' }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify(resumed), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(getWebOnboardingStatus()).resolves.toMatchObject({ session_ready: true, onboarding_required: true, passkeys: 1 });
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      '/api/v1/auth/web/session/onboarding/status',
      '/api/v1/auth/web/session/status',
      '/api/v1/auth/web/session/prepare',
      '/api/v1/auth/web/session/refresh',
      '/api/v1/auth/web/session/status',
      '/api/v1/auth/web/session/onboarding/status',
    ]);
  });
});
