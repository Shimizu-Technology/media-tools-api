import { useState, useEffect, useRef } from 'react';

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
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const stoppedRef = useRef(false);
  const fetcherRef = useRef(fetcher);
  const shouldStopRef = useRef(shouldStop);

  useEffect(() => {
    fetcherRef.current = fetcher;
    shouldStopRef.current = shouldStop;
  }, [fetcher, shouldStop]);

  useEffect(() => {
    if (!enabled) return;

    stoppedRef.current = false;

    const poll = async () => {
      if (stoppedRef.current) return;

      try {
        const result = await fetcherRef.current();
        setData(result);
        setError(null);

        if (shouldStopRef.current?.(result)) {
          stoppedRef.current = true;
          return;
        }
      } catch (err) {
        setError(err instanceof Error ? err : new Error(String(err)));
      }

      if (!stoppedRef.current) {
        timerRef.current = setTimeout(poll, interval);
      }
    };

    poll();

    return () => {
      stoppedRef.current = true;
      if (timerRef.current) {
        clearTimeout(timerRef.current);
      }
    };
  }, [enabled, interval]);

  return { data, error, isPolling: enabled };
}
