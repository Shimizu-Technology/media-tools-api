import { Suspense, type ComponentType } from 'react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import { AlignLeft, Folder, Home, Loader2, Mic, Plus, Settings } from 'lucide-react';
import { ConnectionBanner } from './ConnectionBanner';
import { useAuthContext } from '../contexts/useAuthContext';
import { LibraryActivityProvider } from '../contexts/LibraryActivityContext';
import { AccountMenu } from './AccountMenu';
import { ProcessingLink } from './ProcessingLink';
import { Mark } from './ui/Mark';
import { APP_ROUTES } from '../lib/appRoutes';

type Destination = { to: string; label: string; icon: ComponentType<{ className?: string }>; match: (path: string) => boolean };

const DESTINATIONS: Destination[] = [
  { to: APP_ROUTES.home, label: 'Home', icon: Home, match: (path) => path === APP_ROUTES.home },
  { to: APP_ROUTES.library, label: 'Library', icon: AlignLeft, match: (path) => path.startsWith(APP_ROUTES.library) || path.startsWith('/app/items/') },
  { to: APP_ROUTES.collections, label: 'Collections', icon: Folder, match: (path) => path.startsWith(APP_ROUTES.collections) },
  { to: APP_ROUTES.settings, label: 'Settings', icon: Settings, match: (path) => path.startsWith(APP_ROUTES.settings) },
];

const RECORD_PATH = `${APP_ROUTES.add}?record=1`;

/**
 * The signed-in frame. Phones get the bottom bar with a raised Record button on
 * every tab; an item is a pushed screen with its own Ask button, so the bar
 * steps aside there. Desktop gets a sidebar with Record at the top.
 */
export function AppShell() {
  return <LibraryActivityProvider><AppShellContent /></LibraryActivityProvider>;
}

function AppShellContent() {
  const { pathname } = useLocation();
  const onItem = pathname.startsWith('/app/items/');

  return (
    <div className="min-h-dvh bg-background text-text">
      <a href="#main" data-app-chrome className="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[60] focus:rounded-md focus:bg-surface focus:px-4 focus:py-3 focus:shadow-overlay">Skip to content</a>
      <Sidebar pathname={pathname} />
      <div className="md:pl-[var(--sidebar-width)]">
        <ConnectionBanner />
        <main id="main" className="mx-auto w-full max-w-6xl pb-[calc(env(safe-area-inset-bottom)+6.5rem)] pl-[max(1rem,env(safe-area-inset-left))] pr-[max(1rem,env(safe-area-inset-right))] pt-[max(0.75rem,env(safe-area-inset-top))] md:px-8 md:pb-10 md:pt-8">
          {/* The bars stay put while the next screen's code loads. */}
          <Suspense fallback={<div className="flex min-h-[40dvh] items-center justify-center" role="status"><Loader2 className="h-5 w-5 animate-spin text-text-secondary" /><span className="sr-only">Loading</span></div>}>
            <Outlet />
          </Suspense>
        </main>
      </div>
      {!onItem && <TabBar pathname={pathname} />}
    </div>
  );
}

function Sidebar({ pathname }: { pathname: string }) {
  const { accountAuthEnabled, isAuthenticated } = useAuthContext();
  return (
    <aside data-app-chrome className="fixed inset-y-0 left-0 z-30 hidden w-[var(--sidebar-width)] flex-col border-r border-separator bg-tab-bar px-3 pb-3 pt-5 md:flex">
      <Link to={APP_ROUTES.home} aria-label="Media Tools home" className="mx-1 flex min-h-11 items-center gap-2.5 rounded-md px-1">
        <Mark size={30} />
        <span className="font-display text-[1.125rem] font-extrabold tracking-[-0.01em]">Media Tools</span>
      </Link>
      <Link to={RECORD_PATH} className="pressable mt-5 flex min-h-14 items-center justify-center gap-2 rounded-full bg-hero font-display text-[1.0625rem] font-extrabold text-on-hero shadow-raised hover:opacity-95">
        <Mic className="h-5 w-5" aria-hidden="true" />Record
      </Link>
      <Link to={APP_ROUTES.add} className="pressable mt-2 flex min-h-11 items-center justify-center gap-2 rounded-full text-callout font-semibold text-accent-text hover:bg-fill">
        <Plus className="h-4 w-4" aria-hidden="true" />Add a link or file
      </Link>
      <nav aria-label="Main" className="mt-4 space-y-0.5">
        {DESTINATIONS.map((destination) => {
          const active = destination.match(pathname);
          return (
            <NavLink key={destination.to} to={destination.to} end={destination.to === APP_ROUTES.home} aria-current={active ? 'page' : undefined} className={`flex min-h-11 items-center gap-3 rounded-md px-3 text-body font-semibold transition-colors ${active ? 'bg-surface-2 text-accent-text' : 'text-text-secondary hover:bg-fill hover:text-text'}`}>
              <destination.icon className="h-5 w-5 shrink-0" />{destination.label}
            </NavLink>
          );
        })}
      </nav>
      <div className="flex-1" />
      <ProcessingLink className="self-start" />
      {accountAuthEnabled && isAuthenticated && <AccountMenu />}
    </aside>
  );
}

function TabBar({ pathname }: { pathname: string }) {
  return (
    <nav data-app-chrome data-tab-bar aria-label="Main" className="fixed inset-x-0 bottom-0 z-30 border-t border-separator bg-tab-bar pb-[env(safe-area-inset-bottom)] pl-[env(safe-area-inset-left)] pr-[env(safe-area-inset-right)] md:hidden">
      <div className="mx-auto grid max-w-lg grid-cols-[1fr_1fr_1.05fr_1fr_1fr]">
        {DESTINATIONS.slice(0, 2).map((destination) => <Tab key={destination.to} destination={destination} active={destination.match(pathname)} />)}
        <div className="flex justify-center">
          <Link to={RECORD_PATH} aria-label="Record" className="pressable -mt-[1.375rem] flex h-14 w-14 items-center justify-center rounded-full bg-hero text-on-hero shadow-[0_0_0_5px_var(--color-background)]">
            <Mic className="h-6 w-6" aria-hidden="true" />
          </Link>
        </div>
        {DESTINATIONS.slice(2).map((destination) => <Tab key={destination.to} destination={destination} active={destination.match(pathname)} />)}
      </div>
    </nav>
  );
}

function Tab({ destination, active }: { destination: Destination; active: boolean }) {
  return (
    <NavLink to={destination.to} end={destination.to === APP_ROUTES.home} aria-current={active ? 'page' : undefined} className={`flex min-h-[3.5rem] min-w-0 flex-col items-center justify-center gap-0.5 text-[0.6875rem] font-semibold leading-none ${active ? 'text-accent-text' : 'text-text-secondary'}`}>
      <destination.icon className="h-[22px] w-[22px]" />
      <span className="max-w-full truncate">{destination.label}</span>
    </NavLink>
  );
}
