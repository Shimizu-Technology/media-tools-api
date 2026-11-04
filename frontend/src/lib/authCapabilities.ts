/** What the server currently allows, read from GET /api/v1/health. */
export type AuthCapabilities = {
  /** Email and password sign-in is enabled. */
  passwordAuth: boolean;
  /** Codes can be emailed to reset a password (also how accounts without a password get one). */
  passwordReset: boolean;
  /** New accounts may be created. Hidden unless the server says true. */
  signup: boolean;
};

export type CapabilityState =
  | { status: 'unknown' }
  | ({ status: 'ready' } & AuthCapabilities);

type HealthBody = {
  signup_enabled?: unknown;
  password_auth_enabled?: unknown;
  auth_capabilities?: { password_reset?: unknown; email_codes?: unknown } | null;
};

/** Pure so it can be tested without a network. */
export function parseCapabilities(body: HealthBody | null): AuthCapabilities {
  const passwordAuth = body?.password_auth_enabled === true;
  const caps = body?.auth_capabilities;
  return {
    passwordAuth,
    // Reset needs both the flag and emailed codes; fall back to password auth
    // for servers that predate the capability map.
    passwordReset: passwordAuth && (caps ? caps.password_reset === true && caps.email_codes !== false : true),
    signup: passwordAuth && body?.signup_enabled === true,
  };
}

export async function fetchCapabilities(): Promise<CapabilityState> {
  try {
    const response = await fetch('/api/v1/health', { cache: 'no-store', credentials: 'same-origin' });
    if (!response.ok) return { status: 'unknown' };
    return { status: 'ready', ...parseCapabilities(await response.json() as HealthBody) };
  } catch {
    return { status: 'unknown' };
  }
}
