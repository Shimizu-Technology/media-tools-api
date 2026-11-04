import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AccountAuthError, finishPasswordReset, listDevices, nextUsageReset, revokeDevice, secondsToMinutes, startPasswordReset, startSignup, usageFraction, verifySignup } from './accountAuth';
import { resetWebSessionState, setWebSessionActive } from './webSession';

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });
const receipt = () => json({ message: 'If this request is eligible, an email will arrive shortly' }, 202);

beforeEach(() => {
  vi.restoreAllMocks();
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { cookie: 'mta_web_csrf=csrf-token' } });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { dispatchEvent: vi.fn() } });
  resetWebSessionState();
  setWebSessionActive(true);
});

describe('signed-out account flows', () => {
  it('treats the generic 202 receipt as success without learning whether the account exists', async () => {
    const fetchMock = vi.fn().mockResolvedValue(receipt());
    vi.stubGlobal('fetch', fetchMock);
    await expect(startSignup(' New@Example.com ', ' Pat ')).resolves.toBeUndefined();
    await expect(startPasswordReset('nobody@example.com')).resolves.toBeUndefined();
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual(['/api/v1/auth/signup', '/api/v1/auth/password/forgot']);
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body))).toEqual({ email: 'New@Example.com', name: 'Pat' });
  });

  it('sends the code and password together and never stores them', async () => {
    const storage = { setItem: vi.fn(), getItem: vi.fn() };
    Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: storage });
    const fetchMock = vi.fn().mockResolvedValue(json({ verified: true, sign_in_required: true }));
    vi.stubGlobal('fetch', fetchMock);
    await verifySignup('a@example.com', ' 123456 ', 'a long enough passphrase');
    await finishPasswordReset('a@example.com', '123456', 'another long passphrase');
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body))).toEqual({ email: 'a@example.com', code: '123456', password: 'a long enough passphrase' });
    expect(storage.setItem).not.toHaveBeenCalled();
  });

  it('maps stable API errors to plain messages', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ error: 'invalid_code', message: 'x', code: 400 }, 400)));
    await expect(verifySignup('a@example.com', '000000', 'a long enough passphrase')).rejects.toMatchObject({ code: 'invalid_code', message: expect.stringContaining('not valid or has expired') });
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ error: 'password_compromised', message: 'x', code: 400 }, 400)));
    await expect(verifySignup('a@example.com', '000000', 'password1234')).rejects.toMatchObject({ code: 'password_compromised' });
  });

  it('honours Retry-After on a throttled request and marks it retryable', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ error: 'rate_limit_exceeded', message: 'x', code: 429 }, 429, { 'Retry-After': '120' })));
    const error = await startPasswordReset('a@example.com').catch((caught: unknown) => caught) as AccountAuthError;
    expect(error.retryable).toBe(true);
    expect(error.retryAfterSeconds).toBe(120);
    expect(error.message).toContain('2 minutes');
  });

  it('reports a network failure as retryable', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')));
    const error = await startSignup('a@example.com', '').catch((caught: unknown) => caught) as AccountAuthError;
    expect(error.code).toBe('network_error');
    expect(error.retryable).toBe(true);
  });

  it('reports a rejected 403 signup_disabled without retrying', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(json({ error: 'signup_disabled', message: 'x', code: 403 }, 403)));
    const error = await startSignup('a@example.com', '').catch((caught: unknown) => caught) as AccountAuthError;
    expect(error.code).toBe('signup_disabled');
    expect(error.retryable).toBe(false);
  });
});

describe('devices and usage', () => {
  it('lists only active sessions and tolerates a null list', async () => {
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce(json({ sessions: [{ id: 'a', revoked_at: null }, { id: 'b', revoked_at: '2026-01-01T00:00:00Z' }] }))
      .mockResolvedValueOnce(json({ sessions: null })));
    await expect(listDevices()).resolves.toEqual([{ id: 'a', revoked_at: null }]);
    await expect(listDevices()).resolves.toEqual([]);
  });

  it('revokes a device with the CSRF header and treats an already-gone device as done', async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(null, { status: 204 })).mockResolvedValueOnce(json({ error: 'not_found' }, 404));
    vi.stubGlobal('fetch', fetchMock);
    await expect(revokeDevice('abc')).resolves.toBeUndefined();
    await expect(revokeDevice('abc')).resolves.toBeUndefined();
    expect(fetchMock.mock.calls[0][0]).toBe('/api/v1/auth/sessions/abc');
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: 'DELETE', headers: { 'X-CSRF-Token': 'csrf-token' } });
  });

  it('computes minutes, fractions and the UTC reset date', () => {
    expect(secondsToMinutes(60)).toBe(1);
    expect(secondsToMinutes(61)).toBe(2);
    expect(secondsToMinutes(-5)).toBe(0);
    expect(usageFraction(30, 300)).toBeCloseTo(0.1);
    expect(usageFraction(900, 300)).toBe(1);
    expect(usageFraction(5, 0)).toBe(0);
    expect(nextUsageReset('2026-11-01T00:00:00Z')?.toISOString()).toBe('2026-12-01T00:00:00.000Z');
    expect(nextUsageReset('2026-12-01T00:00:00Z')?.toISOString()).toBe('2027-01-01T00:00:00.000Z');
    expect(nextUsageReset('nonsense')).toBeNull();
  });
});
