import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { getErrorMessage, isAPIError, listLibraryItems, type LibraryItem } from '../lib/api';
import { LIBRARY_ACTIVITY_CHANGED_EVENT } from '../lib/libraryActivityEvents';
import { LibraryActivityContext } from './libraryActivityContextValue';

const ACTIVE_JOB_POLL_INTERVAL_MS = 8000;
const POLL_ERROR_RETRY_MS = 30000;
const ACTIVE_JOBS_PER_PAGE = 100;

interface LibraryActivityProviderProps {
  children: ReactNode;
}

async function listAllActiveJobs(): Promise<LibraryItem[]> {
  const firstPage = await listLibraryItems({
    status: 'active',
    page: 1,
    per_page: ACTIVE_JOBS_PER_PAGE,
    archive: 'all',
  });
  if (firstPage.total_pages <= 1) return firstPage.data;

  const remainingPages = await Promise.all(
    Array.from({ length: firstPage.total_pages - 1 }, (_, index) => (
      listLibraryItems({
        status: 'active',
        page: index + 2,
        per_page: ACTIVE_JOBS_PER_PAGE,
        archive: 'all',
      })
    )),
  );

  const jobsByID = new Map(
    [firstPage, ...remainingPages]
      .flatMap((page) => page.data)
      .map((item) => [`${item.item_type}-${item.id}`, item]),
  );
  return [...jobsByID.values()];
}

/**
 * Shares the complete active-job snapshot and its adaptive polling lifecycle
 * across the application shell and Processing Center.
 */
export function LibraryActivityProvider({ children }: LibraryActivityProviderProps) {
  const [activeItems, setActiveItems] = useState<LibraryItem[]>([]);
  const [activeJobCount, setActiveJobCount] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState('');
  const mountedRef = useRef(false);
  const inFlightRef = useRef(false);
  const queuedRefreshRef = useRef(false);
  const activeJobCountRef = useRef(0);
  const timerRef = useRef<number | undefined>(undefined);
  const refreshRef = useRef<(showLoading?: boolean) => Promise<void>>(async () => undefined);

  const clearScheduledRefresh = useCallback(() => {
    if (timerRef.current !== undefined) {
      window.clearTimeout(timerRef.current);
      timerRef.current = undefined;
    }
  }, []);

  const scheduleRefresh = useCallback((shouldPoll: boolean, delay = ACTIVE_JOB_POLL_INTERVAL_MS) => {
    clearScheduledRefresh();
    if (mountedRef.current && shouldPoll && document.visibilityState === 'visible') {
      timerRef.current = window.setTimeout(() => { void refreshRef.current(); }, delay);
    }
  }, [clearScheduledRefresh]);

  const refresh = useCallback(async (showLoading = false) => {
    if (!mountedRef.current) return;
    if (inFlightRef.current) {
      queuedRefreshRef.current = true;
      return;
    }

    inFlightRef.current = true;
    clearScheduledRefresh();
    if (showLoading) setIsLoading(true);

    let shouldPoll = activeJobCountRef.current > 0;
    let nextDelay = ACTIVE_JOB_POLL_INTERVAL_MS;
    try {
      const activeJobs = await listAllActiveJobs();
      if (!mountedRef.current) return;
      activeJobCountRef.current = activeJobs.length;
      shouldPoll = activeJobs.length > 0;
      setActiveItems(activeJobs);
      setActiveJobCount(activeJobs.length);
      setError('');
    } catch (err) {
      if (!mountedRef.current) return;
      setError(getErrorMessage(err));
      // If the initial request was rate-limited, make one recovery attempt even
      // though we do not yet know whether an active job exists.
      shouldPoll = shouldPoll || (isAPIError(err) && err.code === 429);
      nextDelay = isAPIError(err) && err.retry_after_seconds
        ? Math.max(ACTIVE_JOB_POLL_INTERVAL_MS, err.retry_after_seconds * 1000)
        : POLL_ERROR_RETRY_MS;
    } finally {
      inFlightRef.current = false;
      if (mountedRef.current) setIsLoading(false);
      if (mountedRef.current && queuedRefreshRef.current) {
        queuedRefreshRef.current = false;
        queueMicrotask(() => { void refreshRef.current(); });
      } else {
        scheduleRefresh(shouldPoll, nextDelay);
      }
    }
  }, [clearScheduledRefresh, scheduleRefresh]);

  useEffect(() => {
    refreshRef.current = refresh;
  }, [refresh]);

  useEffect(() => {
    mountedRef.current = true;

    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        void refreshRef.current();
      } else {
        clearScheduledRefresh();
      }
    };
    const handleActivityChanged = () => {
      if (document.visibilityState === 'visible') void refreshRef.current();
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    window.addEventListener(LIBRARY_ACTIVITY_CHANGED_EVENT, handleActivityChanged);
    if (document.visibilityState === 'visible') {
      void refreshRef.current(true);
    } else {
      setIsLoading(false);
    }

    return () => {
      mountedRef.current = false;
      clearScheduledRefresh();
      document.removeEventListener('visibilitychange', handleVisibilityChange);
      window.removeEventListener(LIBRARY_ACTIVITY_CHANGED_EVENT, handleActivityChanged);
    };
  }, [clearScheduledRefresh]);

  return (
    <LibraryActivityContext.Provider value={{ activeItems, activeJobCount, isLoading, error, refresh }}>
      {children}
    </LibraryActivityContext.Provider>
  );
}
