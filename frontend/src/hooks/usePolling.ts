import { useState, useEffect, useRef, useCallback } from 'react';

/**
 * Custom hook for polling an async function at intervals.
 * Automatically stops when the shouldStop condition is met.
 */
export function usePolling<T>(
  fetcher: () => Promise<T>,
  options: {
    interval?: number;
    enabled?: boolean;
    shouldStop?: (data: T) => boolean;
  } = {}
) {
  const { interval = 2000, enabled = true, shouldStop } = options;
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [isPolling, setIsPolling] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const stoppedRef = useRef(false);

  const poll = useCallback(async () => {
    if (stoppedRef.current) return;

    try {
      const result = await fetcher();
      setData(result);
      setError(null);

      // Check if we should stop polling
      if (shouldStop?.(result)) {
        stoppedRef.current = true;
        setIsPolling(false);
        return;
      }
    } catch (err) {
      setError(err instanceof Error ? err : new Error(String(err)));
    }

    // Schedule next poll
    if (!stoppedRef.current) {
      timerRef.current = setTimeout(poll, interval);
    }
  }, [fetcher, interval, shouldStop]);

  useEffect(() => {
    if (!enabled) return;

    stoppedRef.current = false;
    setIsPolling(true);
    poll();

    return () => {
      stoppedRef.current = true;
      if (timerRef.current) {
        clearTimeout(timerRef.current);
      }
    };
  }, [enabled, poll]);

  return { data, error, isPolling };
}
