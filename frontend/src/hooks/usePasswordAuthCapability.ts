import { useCallback, useEffect, useState } from 'react';

export type PasswordAuthCapability = 'unknown' | 'enabled' | 'disabled';

let capability: PasswordAuthCapability = 'unknown';
let request: Promise<void> | null = null;
const listeners = new Set<(value: PasswordAuthCapability) => void>();

function publish(value: PasswordAuthCapability) {
  capability = value;
  listeners.forEach((listener) => listener(value));
}

async function loadCapability() {
  if (request) return request;
  request = fetch('/api/v1/health', {
    cache: 'no-store',
    credentials: 'same-origin',
  })
    .then(async (response) => {
      if (!response.ok) throw new Error('health check failed');
      const health = await response.json() as { password_auth_enabled?: boolean };
      publish(health.password_auth_enabled === true ? 'enabled' : 'disabled');
    })
    .catch(() => publish('unknown'))
    .finally(() => { request = null; });
  return request;
}

/**
 * Shares the server's rollout capability across sign-in and Settings. A
 * failed probe stays unknown rather than pretending the feature was disabled,
 * and foreground/online events retry after short outages or flag changes.
 */
export function usePasswordAuthCapability() {
  const [status, setStatus] = useState<PasswordAuthCapability>(capability);
  const [checking, setChecking] = useState(false);

  const refresh = useCallback(async () => {
    setChecking(true);
    try { await loadCapability(); } finally { setChecking(false); }
  }, []);

  useEffect(() => {
    listeners.add(setStatus);
    void refresh();
    const retry = () => { void refresh(); };
    window.addEventListener('online', retry);
    window.addEventListener('focus', retry);
    return () => {
      listeners.delete(setStatus);
      window.removeEventListener('online', retry);
      window.removeEventListener('focus', retry);
    };
  }, [refresh]);

  return { status, checking, refresh };
}
