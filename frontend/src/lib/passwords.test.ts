import { beforeEach, describe, expect, it, vi } from 'vitest';
import { signInWithPassword } from './passwords';

beforeEach(() => {
  vi.restoreAllMocks();
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: { cookie: 'mta_web_csrf=csrf-token' },
  });
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: { dispatchEvent: vi.fn() },
  });
});

describe('web password sign-in', () => {
  it('prepares the HttpOnly successor, signs in, and verifies the committed session', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), {
        status: 201,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(signInWithPassword(' owner@example.com ', 'aaaaaaaaaaaaaaa')).resolves.toBeUndefined();

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual([
      '/api/v1/auth/web/session/password/prepare',
      '/api/v1/auth/web/session/password/finish',
      '/api/v1/auth/web/session/status',
    ]);
    expect(JSON.parse(String(fetchMock.mock.calls[1][1]?.body))).toEqual({
      email: 'owner@example.com',
      password: 'aaaaaaaaaaaaaaa',
    });
  });

  it('retries the identical finish request after a lost response', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockRejectedValueOnce(new TypeError('response lost'))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), {
        status: 201,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(signInWithPassword('owner@example.com', 'aaaaaaaaaaaaaaa')).resolves.toBeUndefined();
    expect(fetchMock.mock.calls[2][1]?.body).toBe(fetchMock.mock.calls[1][1]?.body);
  });

  it('does not mistake an existing cookie session for a lost password response', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockRejectedValueOnce(new TypeError('first response lost'))
      .mockRejectedValueOnce(new TypeError('retry response lost'))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'old-user' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(signInWithPassword('owner@example.com', 'aaaaaaaaaaaaaaa'))
      .rejects.toMatchObject({ code: 'network_error' });
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it('does not treat a rejected password as success because another session exists', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'invalid_credentials', message: 'Email or password is incorrect' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'old-user' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(signInWithPassword('owner@example.com', 'aaaaaaaaaaaaaaa'))
      .rejects.toMatchObject({ code: 'invalid_credentials' });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('rejects token-bearing JSON even when the server reports success', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, access_token: 'secret' }), {
        status: 201,
        headers: { 'Content-Type': 'application/json' },
      }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(signInWithPassword('owner@example.com', 'aaaaaaaaaaaaaaa'))
      .rejects.toMatchObject({ code: 'unsafe_response' });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
