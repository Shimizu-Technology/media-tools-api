import { beforeEach, describe, expect, it, vi } from 'vitest';
import { bootstrapWebSession, reconcileWebSessionWithClerk, webSessionConflictsWithClerk } from './webSession';

beforeEach(() => {
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { cookie: 'mta_web_csrf=csrf-token' } });
  vi.restoreAllMocks();
});

describe('web session safety', () => {
  it('detects an old cookie session under a different active Clerk account', () => {
    const alice = { authenticated: true as const, user_id: 'stable-alice', clerk_id: 'clerk_alice' };
    expect(webSessionConflictsWithClerk(alice, 'clerk_bob')).toBe(true);
    expect(webSessionConflictsWithClerk(alice, 'clerk_alice')).toBe(false);
    expect(webSessionConflictsWithClerk(alice, null)).toBe(false);
    expect(webSessionConflictsWithClerk({ ...alice, clerk_id: null }, 'clerk_bob')).toBe(true);
  });

  it('revokes Alice before allowing Bob and fails closed on a revocation outage', async () => {
    const alice = { authenticated: true as const, user_id: 'stable-alice', clerk_id: 'clerk_alice' };
    const revoke = vi.fn().mockResolvedValue(undefined);
    await expect(reconcileWebSessionWithClerk(alice, 'clerk_bob', revoke)).resolves.toBeNull();
    expect(revoke).toHaveBeenCalledOnce();

    const unavailable = vi.fn().mockRejectedValue(new Error('database unavailable'));
    await expect(reconcileWebSessionWithClerk(alice, 'clerk_bob', unavailable)).rejects.toThrow('database unavailable');
  });

  it('retries Clerk bootstrap with the same prepared HttpOnly successor after a lost response', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockRejectedValueOnce(new TypeError('response lost'))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-1', clerk_id: 'clerk_alice' }), { status: 201, headers: { 'Content-Type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(bootstrapWebSession('clerk-jwt', 'clerk_alice')).resolves.toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(fetchMock.mock.calls[0][0]).toContain('/bootstrap/prepare');
    expect(fetchMock.mock.calls[1][0]).toContain('/bootstrap');
    expect(fetchMock.mock.calls[2][0]).toContain('/bootstrap');
    expect(fetchMock.mock.calls[1][1]).toEqual(fetchMock.mock.calls[2][1]);
  });

  it('rejects a bootstrap result for a different Clerk subject', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ user_id: 'user-bob', clerk_id: 'clerk_bob' }), { status: 201, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(bootstrapWebSession('clerk-jwt', 'clerk_alice')).resolves.toBe(false);
    expect(fetchMock.mock.calls[2][0]).toContain('/logout');
  });

  it('revokes a mismatched cookie found while probing an uncertain bootstrap', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(null, { status: 400 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ authenticated: true, user_id: 'user-bob', clerk_id: 'clerk_bob' }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(bootstrapWebSession('clerk-jwt', 'clerk_alice')).resolves.toBe(false);
    expect(fetchMock.mock.calls[3][0]).toContain('/logout');
  });
});
