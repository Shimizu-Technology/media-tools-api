import { describe, expect, it, vi } from 'vitest';
import { fetchCapabilities, parseCapabilities } from './authCapabilities';

describe('auth capabilities from /health', () => {
  it('shows sign-up only when the server says signup_enabled is true', () => {
    const base = { password_auth_enabled: true, auth_capabilities: { email_codes: true, password_reset: true } };
    expect(parseCapabilities({ ...base, signup_enabled: true }).signup).toBe(true);
    expect(parseCapabilities({ ...base, signup_enabled: false }).signup).toBe(false);
    expect(parseCapabilities({ ...base }).signup).toBe(false);
    expect(parseCapabilities({ ...base, signup_enabled: 'true' }).signup).toBe(false);
  });

  it('never offers sign-up or reset without password auth', () => {
    const caps = parseCapabilities({ signup_enabled: true, password_auth_enabled: false, auth_capabilities: { email_codes: true, password_reset: true } });
    expect(caps).toEqual({ passwordAuth: false, passwordReset: false, signup: false });
  });

  it('needs the reset capability and emailed codes for forgot password', () => {
    expect(parseCapabilities({ password_auth_enabled: true, auth_capabilities: { password_reset: false, email_codes: true } }).passwordReset).toBe(false);
    expect(parseCapabilities({ password_auth_enabled: true, auth_capabilities: { password_reset: true, email_codes: false } }).passwordReset).toBe(false);
    expect(parseCapabilities({ password_auth_enabled: true }).passwordReset).toBe(true);
  });

  it('stays unknown, not disabled, when the server cannot be reached', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')));
    await expect(fetchCapabilities()).resolves.toEqual({ status: 'unknown' });
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('bad gateway', { status: 502 })));
    await expect(fetchCapabilities()).resolves.toEqual({ status: 'unknown' });
  });
});
