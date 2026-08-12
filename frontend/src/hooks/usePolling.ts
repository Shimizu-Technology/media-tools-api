import { useState, useEffect, useRef } from 'react';
import { getErrorMessage, isAPIError } from '../lib/api';

/**
 * Custom hook for polling an async function at intervals.
 * Automatically stops when the shouldStop condition is met, pauses while the
 * document is hidden, and respects server-provided 429 retry timing.
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
  const [isPolling, setIsPolling] = useState(enabled);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const stoppedRef = useRef(false);
  const inFlightRef = useRef(false);
  const fetcherRef = useRef(fetcher);
  const shouldStopRef = useRef(shouldStop);

  useEffect(() => {
    fetcherRef.current = fetcher;
    shouldStopRef.current = shouldStop;
  }, [fetcher, shouldStop]);

  useEffect(() => {
    if (!enabled) {
      queueMicrotask(() => setIsPolling(false));
      return;
    }

    stoppedRef.current = false;
    queueMicrotask(() => setIsPolling(true));

    const schedule = (delay: number) => {
      if (!stoppedRef.current && document.visibilityState === 'visible') {
        timerRef.current = setTimeout(poll, delay);
      }
    };

    const poll = async () => {
      if (stoppedRef.current || inFlightRef.current || document.visibilityState !== 'visible') return;

      inFlightRef.current = true;
      let nextDelay = interval;

      try {
        const result = await fetcherRef.current();
        setData(result);
        setError(null);

        if (shouldStopRef.current?.(result)) {
          stoppedRef.current = true;
          setIsPolling(false);
          return;
        }
      } catch (err) {
        setError(err instanceof Error ? err : new Error(getErrorMessage(err)));
        if (isAPIError(err) && err.code === 429 && err.retry_after_seconds) {
          nextDelay = Math.max(interval, err.retry_after_seconds * 1000);
        }
      } finally {
        inFlightRef.current = false;
      }

      schedule(nextDelay);
    };

    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        void poll();
      } else if (timerRef.current) {
        clearTimeout(timerRef.current);
        timerRef.current = null;
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    void poll();

    return () => {
      stoppedRef.current = true;
      document.removeEventListener('visibilitychange', handleVisibilityChange);
      if (timerRef.current) {
        clearTimeout(timerRef.current);
      }
    };
  }, [enabled, interval]);

  return { data, error, isPolling };
}
