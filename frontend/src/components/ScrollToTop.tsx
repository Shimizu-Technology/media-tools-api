import { useEffect } from 'react';
import { useLocation } from 'react-router-dom';

/** Reset document scroll for actual page navigation while preserving filter/search changes. */
export function ScrollToTop() {
  const { pathname } = useLocation();

  useEffect(() => {
    window.scrollTo({ top: 0, left: 0, behavior: 'auto' });
  }, [pathname]);

  return null;
}
