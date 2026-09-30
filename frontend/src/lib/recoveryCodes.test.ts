import { beforeEach, describe, expect, it, vi } from 'vitest';
import { beginRecoveryCodeRotation, confirmRecoveryCodeRotation, getRecoveryCodeStatus, prepareRecoveryCodeSignIn, signInWithRecoveryCode } from './recoveryCodes';

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() { return values.size; }, clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null, key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => { values.delete(key); }, setItem: (key, value) => { values.set(key, value); },
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: memoryStorage() });
  Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: memoryStorage() });
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { cookie: 'mta_web_csrf=csrf-token' } });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { dispatchEvent: vi.fn() } });
});

describe('web recovery sign-in', () => {
  it('replaces a stale HttpOnly successor before accepting another code', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'sign_in_not_prepared', message: 'Start recovery sign-in again' }), { status: 400, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(prepareRecoveryCodeSignIn()).resolves.toBe(false);
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      '/api/v1/auth/web/session/recovery/prepare',
      '/api/v1/auth/web/session/recovery/finish',
      '/api/v1/auth/web/session/recovery/prepare',
    ]);
    expect(JSON.parse(String(fetchMock.mock.calls[1][1]?.body))).toEqual({});
  });

  it('keeps a usable successor after an ordinary wrong code', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'invalid_recovery_code', message: 'Recovery code is invalid or already used' }), { status: 401, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'invalid_recovery_code', message: 'Recovery code is invalid or already used' }), { status: 401, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(prepareRecoveryCodeSignIn()).resolves.toBe(false);
    await expect(signInWithRecoveryCode('MTR-WRONG')).rejects.toMatchObject({ code: 'invalid_recovery_code' });
    await expect(signInWithRecoveryCode('MTR-RIGHT')).resolves.toBeUndefined();
    expect(fetchMock.mock.calls.filter(([url]) => String(url).endsWith('/prepare'))).toHaveLength(1);
  });

  it('retries a lost finish response with the same in-memory code and stores no credential', async () => {
    const localSet = vi.spyOn(localStorage, 'setItem');
    const sessionSet = vi.spyOn(sessionStorage, 'setItem');
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError('response lost'))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(signInWithRecoveryCode('MTR-ONE-TIME-CODE')).resolves.toBeUndefined();
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body))).toEqual({ code: 'MTR-ONE-TIME-CODE' });
    expect(fetchMock.mock.calls[1][1]?.body).toBe(fetchMock.mock.calls[0][1]?.body);
    expect(localSet).not.toHaveBeenCalled();
    expect(sessionSet).not.toHaveBeenCalled();
  });

  it('prepares once and retries the same code when the form successor becomes stale', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'sign_in_not_prepared', message: 'Start recovery sign-in again' }), { status: 400, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(signInWithRecoveryCode('MTR-SAVED-CODE')).resolves.toBeUndefined();
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      '/api/v1/auth/web/session/recovery/finish',
      '/api/v1/auth/web/session/recovery/prepare',
      '/api/v1/auth/web/session/recovery/finish',
      '/api/v1/auth/web/session/status',
    ]);
    expect(fetchMock.mock.calls[2][1]?.body).toBe(fetchMock.mock.calls[0][1]?.body);
  });

  it('rejects a token-bearing response even if the server reports success', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({ authenticated: true, access_token: 'secret' }), { status: 201, headers: { 'Content-Type': 'application/json' } })));
    await expect(signInWithRecoveryCode('MTR-CODE')).rejects.toMatchObject({ code: 'unsafe_response' });
  });
});

describe('recovery-code management', () => {
  it('renews an expired access cookie before loading status', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ remaining: 8 }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(getRecoveryCodeStatus()).resolves.toEqual({ remaining: 8 });
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      '/api/v1/auth/recovery',
      '/api/v1/auth/web/session/prepare',
      '/api/v1/auth/web/session/refresh',
      '/api/v1/auth/recovery',
    ]);
  });

  it('keeps the rotation id for explicit idempotent confirmation', async () => {
    const rotation = { rotation_id: '11111111-1111-4111-8111-111111111111', codes: ['MTR-ONE', 'MTR-TWO'] };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(rotation), { status: 201, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ remaining: 2 }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ remaining: 2 }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(beginRecoveryCodeRotation()).resolves.toEqual(rotation);
    await expect(confirmRecoveryCodeRotation(rotation.rotation_id)).resolves.toBe(2);
    await expect(confirmRecoveryCodeRotation(rotation.rotation_id)).resolves.toBe(2);
    expect(JSON.parse(String(fetchMock.mock.calls[1][1]?.body))).toEqual({ rotation_id: rotation.rotation_id });
    expect(fetchMock.mock.calls[2][1]?.body).toBe(fetchMock.mock.calls[1][1]?.body);
  });
});
