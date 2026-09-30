import { beforeEach, describe, expect, it, vi } from 'vitest';
import { getPasskeyStatus, parseCreationOptions, parseRequestOptions, recoverPendingPasskeySignIn, signInWithPasskey } from './passkeys';

class FakePublicKeyCredential {
  id = 'credential-id';
  rawId = new Uint8Array([1, 2, 3]).buffer;
  type = 'public-key';
  response = {};
  authenticatorAttachment = 'platform';
  getClientExtensionResults() { return {}; }
  toJSON() { return { id: this.id, rawId: 'AQID', type: this.type, response: { clientDataJSON: 'AA' } }; }
}

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
  vi.stubGlobal('PublicKeyCredential', FakePublicKeyCredential);
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: memoryStorage() });
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { cookie: 'mta_web_csrf=csrf-token' } });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { isSecureContext: true, dispatchEvent: vi.fn() } });
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { credentials: { get: vi.fn().mockResolvedValue(new FakePublicKeyCredential()) } } });
});

describe('WebAuthn JSON handling', () => {
  it('decodes request and creation fields when browser JSON helpers are unavailable', () => {
    const request = parseRequestOptions({ challenge: 'AQID', allowCredentials: [{ type: 'public-key', id: 'BAUG' }] });
    expect([...new Uint8Array(request.challenge as ArrayBuffer)]).toEqual([1, 2, 3]);
    expect([...new Uint8Array(request.allowCredentials![0].id as ArrayBuffer)]).toEqual([4, 5, 6]);
    const creation = parseCreationOptions({ challenge: 'AQID', rp: { id: 'example.com', name: 'Example' }, user: { id: 'BAUG', name: 'a', displayName: 'A' }, pubKeyCredParams: [] });
    expect([...new Uint8Array(creation.user.id as ArrayBuffer)]).toEqual([4, 5, 6]);
  });
});

describe('passkey response recovery', () => {
  it('journals the ceremony before finish and recovers after reload without another prompt', async () => {
    const begin = { ceremony_id: '11111111-1111-4111-8111-111111111111', options: { challenge: 'AQID' } };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(begin), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockRejectedValueOnce(new TypeError('finish response lost'));
    vi.stubGlobal('fetch', fetchMock);
    await expect(signInWithPasskey()).rejects.toMatchObject({ code: 'network_error' });
    expect(localStorage.getItem('mta:web-passkey-login:v1')).toBe(begin.ceremony_id);

    fetchMock.mockReset()
      .mockResolvedValueOnce(new Response('{}', { status: 201, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    await expect(recoverPendingPasskeySignIn()).resolves.toBe(true);
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body))).toEqual({ ceremony_id: begin.ceremony_id });
    expect(navigator.credentials.get).toHaveBeenCalledTimes(1);
    expect(localStorage.getItem('mta:web-passkey-login:v1')).toBeNull();
  });

  it('renews an expired cookie session before retrying passkey settings', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ count: 1 }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(getPasskeyStatus()).resolves.toEqual({ count: 1 });
    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      '/api/v1/auth/passkeys',
      '/api/v1/auth/web/session/prepare',
      '/api/v1/auth/web/session/refresh',
      '/api/v1/auth/passkeys',
    ]);
  });
});
