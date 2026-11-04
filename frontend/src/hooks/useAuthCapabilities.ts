import { useCallback, useEffect, useState } from 'react';
import { fetchCapabilities, type CapabilityState } from '../lib/authCapabilities';

let shared: CapabilityState = { status: 'unknown' };
let request: Promise<void> | null = null;
const listeners = new Set<(value: CapabilityState) => void>();

function load(): Promise<void> {
  if (request) return request;
  request = fetchCapabilities()
    .then((value) => {
      shared = value;
      listeners.forEach((listener) => listener(value));
    })
    .finally(() => { request = null; });
  return request;
}

/**
 * Shares the server's rollout flags across the sign-in screens and Settings.
 * A failed probe stays `unknown` rather than pretending a feature is off, and
 * foreground/online events retry after short outages or flag changes.
 */
export function useAuthCapabilities() {
  const [state, setState] = useState<CapabilityState>(shared);
  const [checking, setChecking] = useState(false);

  const refresh = useCallback(async () => {
    setChecking(true);
    try { await load(); } finally { setChecking(false); }
  }, []);

  useEffect(() => {
    listeners.add(setState);
    void refresh();
    const retry = () => { void refresh(); };
    window.addEventListener('online', retry);
    window.addEventListener('focus', retry);
    return () => {
      listeners.delete(setState);
      window.removeEventListener('online', retry);
      window.removeEventListener('focus', retry);
    };
  }, [refresh]);

  return { state, checking, refresh };
}
