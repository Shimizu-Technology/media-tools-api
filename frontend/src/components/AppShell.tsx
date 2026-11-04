import { Suspense } from 'react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import { Loader2, Mic, Plus, Settings } from 'lucide-react';
import { ConnectionBanner } from './ConnectionBanner';
import { useAuthContext } from '../contexts/useAuthContext';
import { LibraryActivityProvider } from '../contexts/LibraryActivityContext';
import { useLibraryActivity } from '../contexts/useLibraryActivity';
import { AccountMenu } from './AccountMenu';
import { Mark } from './ui/Mark';
import { buttonClass, iconLinkClass } from './ui/styles';
import { APP_ROUTES } from '../lib/appRoutes';

/**
 * The signed-in frame: one quiet bar with the mark, what is processing, Add,
 * and Settings. The Library owns the record control; there are no tabs.
 */
export function AppShell() {
  return <LibraryActivityProvider><AppShellContent /></LibraryActivityProvider>;
}

function AppShellContent() {
  const location = useLocation();
  const { accountAuthEnabled, isAuthenticated } = useAuthContext();
  const { activeJobCount } = useLibraryActivity();
  const onCapture = location.pathname === APP_ROUTES.add;

  return (
    <div className="min-h-dvh bg-bg text-text">
      <a href="#main" className="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[60] focus:rounded-md focus:bg-surface focus:px-4 focus:py-3 focus:shadow-overlay">Skip to content</a>
      <header className="sticky top-0 z-30 border-b border-separator bg-bar pt-[env(safe-area-inset-top)] backdrop-blur-xl">
        <div className="mx-auto flex h-14 max-w-5xl items-center gap-1 pl-[max(0.75rem,env(safe-area-inset-left))] pr-[max(0.5rem,env(safe-area-inset-right))] sm:px-6">
          <Link to={APP_ROUTES.library} className="-ml-1 flex min-h-11 min-w-11 items-center gap-2.5 rounded-md px-1" aria-label="Media Tools library">
            <Mark size={28} />
            <span className="hidden font-serif text-[1.0625rem] font-semibold tracking-[-0.01em] sm:inline">Media Tools</span>
          </Link>
          <div className="flex-1" />
          {activeJobCount > 0 && (
            <Link to="/app?status=active" className="inline-flex min-h-11 items-center gap-1.5 whitespace-nowrap rounded-full px-3 text-meta font-semibold text-text-secondary hover:bg-fill">
              <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden="true" />
              <span>{activeJobCount} processing</span>
            </Link>
          )}
          {!onCapture && (
            <>
              <div className="hidden items-center gap-1 sm:flex">
                <Link to={APP_ROUTES.add} className={buttonClass({ variant: 'plain' })}>
                  <Plus className="h-4 w-4" aria-hidden="true" />Add
                </Link>
                <Link to={`${APP_ROUTES.add}?record=1`} className={buttonClass({ variant: 'primary' })}>
                  <Mic className="h-4 w-4" aria-hidden="true" />Record
                </Link>
              </div>
              <Link to={APP_ROUTES.add} aria-label="Add a link or file" title="Add a link or file" className={`${iconLinkClass()} sm:hidden`}>
                <Plus className="h-[22px] w-[22px]" aria-hidden="true" />
              </Link>
            </>
          )}
          <NavLink to={APP_ROUTES.settings} aria-label="Settings" title="Settings" className={({ isActive }) => `${iconLinkClass()} ${isActive ? 'bg-fill' : ''}`}>
            <Settings className="h-[22px] w-[22px]" aria-hidden="true" />
          </NavLink>
          {accountAuthEnabled && isAuthenticated && <div className="hidden sm:block"><AccountMenu /></div>}
        </div>
      </header>

      <ConnectionBanner />
      <main id="main" className="mx-auto w-full max-w-5xl pb-[calc(env(safe-area-inset-bottom)+2rem)] pl-[max(1rem,env(safe-area-inset-left))] pr-[max(1rem,env(safe-area-inset-right))] pt-2 sm:px-6 sm:pt-6">
        {/* The bar stays put while the next screen's code loads. */}
        <Suspense fallback={<div className="flex min-h-[40dvh] items-center justify-center" role="status"><Loader2 className="h-5 w-5 animate-spin text-text-secondary" /><span className="sr-only">Loading</span></div>}>
          <Outlet />
        </Suspense>
      </main>
    </div>
  );
}
