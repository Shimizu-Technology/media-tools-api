import { beforeEach, describe, expect, it, vi } from 'vitest';
import { getCurrentUser } from './api';
import { getSessionPhase, isConnectionDegraded, resetWebSessionState, setWebSessionActive } from './webSession';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const empty = (status: number) => new Response(null, { status });
const user = { id: 'user-1', email: 'a@example.com', name: 'A', created_at: '2026-01-01T00:00:00Z' };

beforeEach(() => {
  vi.restoreAllMocks();
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { cookie: 'mta_web_csrf=csrf-token' } });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { dispatchEvent: vi.fn() } });
  resetWebSessionState();
  setWebSessionActive(true);
});

describe('API calls during a signed-in session', () => {
  it('replays a request once after renewing an expired access cookie', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(json({ error: 'unauthorized' }, 401))
      .mockResolvedValueOnce(empty(204))
      .mockResolvedValueOnce(json({ user_id: 'user-1' }))
      .mockResolvedValueOnce(json(user));
    vi.stubGlobal('fetch', fetchMock);
    await expect(getCurrentUser()).resolves.toMatchObject({ id: 'user-1' });
    expect(getSessionPhase()).toBe('authenticated');
  });

  it('signs out when the server explicitly rejects the session', async () => {
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce(json({ error: 'unauthorized' }, 401))
      .mockResolvedValueOnce(json({ error: 'invalid_session' }, 401)));
    await expect(getCurrentUser()).rejects.toMatchObject({ code: 401 });
    expect(getSessionPhase()).toBe('signed_out');
  });

  it('keeps the session and offers a retry when renewal hits a server error', async () => {
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce(json({ error: 'unauthorized' }, 401))
      .mockResolvedValueOnce(json({ error: 'authentication_unavailable' }, 503)));
    await expect(getCurrentUser()).rejects.toMatchObject({ error: 'authentication_unavailable' });
    expect(getSessionPhase()).toBe('authenticated');
    expect(isConnectionDegraded()).toBe(true);
  });

  it('keeps the session through a network outage and recovers on the next success', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValueOnce(new TypeError('Failed to fetch')));
    await expect(getCurrentUser()).rejects.toThrow('Failed to fetch');
    expect(getSessionPhase()).toBe('authenticated');
    expect(isConnectionDegraded()).toBe(true);

    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(json(user)));
    await expect(getCurrentUser()).resolves.toMatchObject({ id: 'user-1' });
    expect(isConnectionDegraded()).toBe(false);
  });

  it.each([502, 504])('keeps the session when the proxy answers %i', async (status) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(json({ error: 'upstream' }, status)));
    await expect(getCurrentUser()).rejects.toBeDefined();
    expect(getSessionPhase()).toBe('authenticated');
    expect(isConnectionDegraded()).toBe(true);
  });

  it('treats a proxy error page (503 without an API error body) as an outage', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response('<html>Service Unavailable</html>', { status: 503 })));
    await expect(getCurrentUser()).rejects.toBeDefined();
    expect(getSessionPhase()).toBe('authenticated');
    expect(isConnectionDegraded()).toBe(true);
  });

  it('does not call a feature-specific 503 from the API an outage', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(json({ error: 'transcription_unavailable', message: 'not configured' }, 503)));
    await expect(getCurrentUser()).rejects.toMatchObject({ error: 'transcription_unavailable' });
    expect(getSessionPhase()).toBe('authenticated');
    expect(isConnectionDegraded()).toBe(false);
  });
});
