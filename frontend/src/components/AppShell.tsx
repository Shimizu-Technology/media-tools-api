import { lazy, Suspense, useEffect, useState, type ComponentType } from 'react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import {
  Activity,
  Boxes,
  ChevronRight,
  Code2,
  FilePlus2,
  FileText,
  FolderOpen,
  Home,
  Library,
  ListTodo,
  Menu,
  PanelLeftClose,
  PanelLeftOpen,
  Plus,
  Settings,
  X,
} from 'lucide-react';
import { useAuthContext } from '../contexts/useAuthContext';
import { LibraryActivityProvider } from '../contexts/LibraryActivityContext';
import { useLibraryActivity } from '../contexts/useLibraryActivity';
import { getHealth } from '../lib/api';

const CLERK_CONFIGURED = Boolean(
  import.meta.env.VITE_CLERK_PUBLISHABLE_KEY && import.meta.env.VITE_CLERK_PUBLISHABLE_KEY !== 'YOUR_PUBLISHABLE_KEY'
);
const LazyClerkUserButton = CLERK_CONFIGURED
  ? lazy(() => import('./ClerkUserButton').then((module) => ({ default: module.ClerkUserButton })))
  : null;

const SIDEBAR_COLLAPSED_KEY = 'mta-app-sidebar-collapsed';

type NavItem = {
  label: string;
  shortLabel?: string;
  to: string;
  icon: ComponentType<{ className?: string }>;
  end?: boolean;
};

const workspaceNav: NavItem[] = [
  { label: 'Home', to: '/app', icon: Home, end: true },
  { label: 'Library', to: '/app/library', icon: Library },
  { label: 'Collections', to: '/app/collections', icon: FolderOpen },
  { label: 'Activity', to: '/app/processing', icon: ListTodo },
];

const developerNav: NavItem[] = [
  { label: 'Developer', to: '/app/developer', icon: Code2, end: true },
  { label: 'Webhooks', to: '/app/developer/webhooks', icon: Boxes },
];

const opsNav: NavItem = { label: 'Ops health', to: '/app/admin/ops', icon: Activity };

const mobileNav: NavItem[] = [
  { label: 'Home', to: '/app', icon: Home, end: true },
  { label: 'Library', to: '/app/library', icon: Library },
  { label: 'Add', to: '/app/new', icon: Plus },
  { label: 'Collections', shortLabel: 'Collections', to: '/app/collections', icon: FolderOpen },
  { label: 'Activity', to: '/app/processing', icon: ListTodo },
];

type PageContext = { eyebrow: string; title: string };

function getPageContext(pathname: string): PageContext {
  if (pathname === '/app') return { eyebrow: 'Workspace', title: 'Home' };
  if (pathname === '/app/new') return { eyebrow: 'Create', title: 'Add media' };
  if (pathname.startsWith('/app/items/')) return { eyebrow: 'Library', title: 'Media item' };
  if (pathname.startsWith('/app/library')) return { eyebrow: 'Workspace', title: 'Library' };
  if (pathname.startsWith('/app/collections/')) return { eyebrow: 'Workspace', title: 'Collection' };
  if (pathname.startsWith('/app/collections')) return { eyebrow: 'Workspace', title: 'Collections' };
  if (pathname.startsWith('/app/processing')) return { eyebrow: 'Workspace', title: 'Activity' };
  if (pathname.startsWith('/app/video')) return { eyebrow: 'Add media', title: 'Video transcript' };
  if (pathname.startsWith('/app/audio')) return { eyebrow: 'Add media', title: 'Recording or audio' };
  if (pathname.startsWith('/app/pdf')) return { eyebrow: 'Add media', title: 'PDF document' };
  if (pathname.startsWith('/app/developer/webhooks')) return { eyebrow: 'Developer', title: 'Webhooks' };
  if (pathname.startsWith('/app/developer')) return { eyebrow: 'Developer', title: 'API access' };
  if (pathname.startsWith('/app/admin/ops')) return { eyebrow: 'Operations', title: 'System health' };
  if (pathname.startsWith('/app/settings')) return { eyebrow: 'Account', title: 'Settings' };
  return { eyebrow: 'Media Tools', title: 'Workspace' };
}

export function AppShell() {
  return <LibraryActivityProvider><AppShellContent /></LibraryActivityProvider>;
}

function AppShellContent() {
  const location = useLocation();
  const [mobileOpen, setMobileOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === 'true'; } catch { return false; }
  });
  const { user, isClerkEnabled } = useAuthContext();
  const { activeJobCount } = useLibraryActivity();
  const page = getPageContext(location.pathname);

  useEffect(() => {
    void getHealth().catch(() => undefined);
  }, []);

  const toggleCollapsed = () => {
    setCollapsed((current) => {
      const next = !current;
      try { localStorage.setItem(SIDEBAR_COLLAPSED_KEY, String(next)); } catch { /* Best-effort preference. */ }
      return next;
    });
  };

  const userName = user?.name || user?.email || 'Media workspace';

  return (
    <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)', color: 'var(--color-text-primary)' }}>
      <aside className={`fixed inset-y-0 left-0 z-40 hidden border-r backdrop-blur-xl transition-[width] duration-200 lg:flex lg:flex-col ${collapsed ? 'w-20' : 'w-64'}`} style={{ backgroundColor: 'var(--color-sidebar-bg)', borderColor: 'var(--color-border)' }}>
        <SidebarContent collapsed={collapsed} onToggleCollapsed={toggleCollapsed} userName={userName} isClerkEnabled={isClerkEnabled} activeJobs={activeJobCount} />
      </aside>

      {mobileOpen && (
        <div className="fixed inset-0 z-50 lg:hidden" role="dialog" aria-modal="true" aria-label="Workspace navigation">
          <button className="absolute inset-0 bg-black/60 backdrop-blur-sm" aria-label="Close navigation" onClick={() => setMobileOpen(false)} />
          <aside className="absolute inset-y-0 left-0 flex w-[86vw] max-w-[340px] flex-col border-r shadow-2xl" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
            <SidebarContent collapsed={false} onToggleCollapsed={toggleCollapsed} userName={userName} isClerkEnabled={isClerkEnabled} activeJobs={activeJobCount} mobile onNavigate={() => setMobileOpen(false)} />
          </aside>
          <button className="absolute left-[calc(min(86vw,340px)+0.75rem)] top-4 flex h-11 w-11 items-center justify-center rounded-full border bg-black/30 text-white backdrop-blur" style={{ borderColor: 'rgba(255,255,255,0.25)' }} onClick={() => setMobileOpen(false)} aria-label="Close navigation">
            <X className="h-5 w-5" />
          </button>
        </div>
      )}

      <div className={`transition-[padding] duration-200 ${collapsed ? 'lg:pl-20' : 'lg:pl-64'}`}>
        <header className="sticky top-0 z-30 border-b backdrop-blur-xl" style={{ backgroundColor: 'var(--color-header-bg)', borderColor: 'var(--color-border)' }}>
          <div className="flex h-16 items-center justify-between gap-3 px-4 sm:px-6 lg:px-8">
            <div className="flex min-w-0 items-center gap-3">
              <button className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-xl border transition-colors hover:bg-[var(--color-nav-hover)] lg:hidden" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={() => setMobileOpen(true)} aria-label="Open navigation">
                <Menu className="h-5 w-5" />
              </button>
              <div className="min-w-0">
                <p className="truncate text-[0.65rem] font-semibold uppercase tracking-[0.2em]" style={{ color: 'var(--color-text-muted)' }}>{page.eyebrow}</p>
                <p className="truncate text-base font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>{page.title}</p>
              </div>
            </div>
            <div className="flex items-center gap-2">
              {activeJobCount > 0 && (
                <Link to="/app/processing" className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-3 text-xs font-semibold" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)', backgroundColor: 'var(--color-surface-elevated)' }}>
                  <span className="relative flex h-2.5 w-2.5"><span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-[var(--color-brand-500)] opacity-50" /><span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-[var(--color-brand-500)]" /></span>
                  <span className="hidden sm:inline">{activeJobCount} active</span>
                  <span className="sm:hidden">{activeJobCount}</span>
                </Link>
              )}
              {location.pathname !== '/app/new' && (
                <Link to="/app/new" className="hidden min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition hover:-translate-y-0.5 sm:inline-flex" style={{ backgroundColor: 'var(--color-brand-500)' }}>
                  <Plus className="h-4 w-4" /> Add media
                </Link>
              )}
              {LazyClerkUserButton && (
                <Suspense fallback={<div className="h-11 w-11 rounded-full" style={{ backgroundColor: 'var(--color-surface-overlay)' }} />}>
                  <LazyClerkUserButton />
                </Suspense>
              )}
            </div>
          </div>
        </header>

        <main className="min-h-[calc(100vh-4rem)] px-4 pb-28 pt-5 sm:px-6 sm:pt-7 lg:px-8 lg:pb-8">
          <Outlet />
        </main>
      </div>

      <MobileBottomNav activeJobs={activeJobCount} />
    </div>
  );
}

function SidebarContent({ collapsed, onToggleCollapsed, userName, isClerkEnabled, activeJobs, mobile = false, onNavigate }: {
  collapsed: boolean;
  onToggleCollapsed: () => void;
  userName: string;
  isClerkEnabled: boolean;
  activeJobs: number;
  mobile?: boolean;
  onNavigate?: () => void;
}) {
  return (
    <div className="flex h-full flex-col p-3">
      <div className={`flex items-center gap-3 border-b pb-4 ${collapsed ? 'justify-center' : 'px-2'}`} style={{ borderColor: 'var(--color-border)' }}>
        <Link to="/app" onClick={onNavigate} className="flex min-h-11 min-w-0 items-center gap-3 rounded-2xl focus-visible:outline-none">
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl shadow-lg shadow-black/10" style={{ backgroundColor: 'var(--color-brand-500)' }}>
            <FileText className="h-5 w-5 text-white" />
          </div>
          {!collapsed && <div className="min-w-0"><p className="truncate text-base font-semibold tracking-tight">Media Tools</p><p className="truncate text-xs" style={{ color: 'var(--color-text-muted)' }}>Private workspace</p></div>}
        </Link>
        {!mobile && !collapsed && (
          <button className="ml-auto hidden h-11 w-11 items-center justify-center rounded-xl border transition-colors hover:bg-[var(--color-nav-hover)] lg:flex" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={onToggleCollapsed} aria-label="Collapse sidebar"><PanelLeftClose className="h-4 w-4" /></button>
        )}
      </div>

      {!mobile && collapsed && (
        <button className="mx-auto mt-3 flex h-11 w-11 items-center justify-center rounded-xl border" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={onToggleCollapsed} aria-label="Expand sidebar"><PanelLeftOpen className="h-4 w-4" /></button>
      )}

      <Link to="/app/new" onClick={onNavigate} title={collapsed ? 'Add media' : undefined} className={`mt-4 flex min-h-12 items-center rounded-2xl font-semibold text-white shadow-lg shadow-black/10 transition hover:-translate-y-0.5 ${collapsed ? 'justify-center' : 'gap-3 px-4'}`} style={{ backgroundColor: 'var(--color-brand-500)' }}>
        <FilePlus2 className="h-5 w-5 shrink-0" />
        {!collapsed && <><span>Add media</span><ChevronRight className="ml-auto h-4 w-4 opacity-70" /></>}
      </Link>

      <nav className="mt-4 flex flex-1 flex-col gap-1 overflow-y-auto" aria-label="Workspace">
        <NavSection items={workspaceNav} collapsed={collapsed} onNavigate={onNavigate} activeJobs={activeJobs} />
        <Divider collapsed={collapsed} label="Developer" />
        <NavSection items={isClerkEnabled ? developerNav : [...developerNav, opsNav]} collapsed={collapsed} onNavigate={onNavigate} />
      </nav>

      <div className={`mt-4 border-t pt-4 ${collapsed ? 'px-0' : 'px-2'}`} style={{ borderColor: 'var(--color-border)' }}>
        <NavLink to="/app/settings" onClick={onNavigate} className={({ isActive }) => navClass(isActive, collapsed)} title="Settings"><Settings className="h-5 w-5 shrink-0" />{!collapsed && <span>Settings</span>}</NavLink>
        {!collapsed && <div className="mt-3 rounded-2xl border p-3" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}><p className="truncate text-sm font-semibold">{userName}</p><p className="mt-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>{isClerkEnabled ? 'Signed in with Clerk' : 'API key development mode'}</p></div>}
      </div>
    </div>
  );
}

function MobileBottomNav({ activeJobs }: { activeJobs: number }) {
  return (
    <nav className="fixed inset-x-0 bottom-0 z-40 border-t px-2 pb-[max(0.5rem,env(safe-area-inset-bottom))] pt-2 backdrop-blur-xl lg:hidden" style={{ backgroundColor: 'var(--color-mobile-nav-bg)', borderColor: 'var(--color-border)' }} aria-label="Primary">
      <div className="mx-auto grid max-w-xl grid-cols-5">
        {mobileNav.map((item) => {
          const Icon = item.icon;
          const isAdd = item.to === '/app/new';
          return (
            <NavLink key={item.to} to={item.to} end={item.end} className={({ isActive }) => `relative flex min-h-14 min-w-0 flex-col items-center justify-center gap-1 rounded-2xl px-1 text-[0.65rem] font-semibold transition ${isAdd ? '-mt-5' : ''} ${isActive ? 'text-[var(--color-brand-500)]' : 'text-[var(--color-text-muted)]'}`}>
              {isAdd ? (
                <span className="flex h-13 w-13 items-center justify-center rounded-2xl text-white shadow-xl shadow-black/20" style={{ backgroundColor: 'var(--color-brand-500)' }}><Icon className="h-6 w-6" /></span>
              ) : (
                <span className="relative"><Icon className="h-5 w-5" />{item.to === '/app/processing' && activeJobs > 0 && <span className="absolute -right-2 -top-1 h-2.5 w-2.5 rounded-full bg-[var(--color-brand-500)] ring-2 ring-[var(--color-mobile-nav-bg)]" />}</span>
              )}
              <span className={isAdd ? 'text-[var(--color-brand-500)]' : 'truncate'}>{item.shortLabel || item.label}</span>
            </NavLink>
          );
        })}
      </div>
    </nav>
  );
}

function NavSection({ items, collapsed, onNavigate, activeJobs = 0 }: { items: NavItem[]; collapsed: boolean; onNavigate?: () => void; activeJobs?: number }) {
  return <div className="space-y-1">{items.map((item) => { const Icon = item.icon; return <NavLink key={item.to} to={item.to} end={item.end} onClick={onNavigate} className={({ isActive }) => navClass(isActive, collapsed)} title={collapsed ? item.label : undefined}><Icon className="h-5 w-5 shrink-0" />{!collapsed && <span>{item.label}</span>}{!collapsed && item.to === '/app/processing' && activeJobs > 0 ? <span className="ml-auto rounded-full px-2 py-0.5 text-xs font-semibold" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>{activeJobs}</span> : !collapsed && <ChevronRight className="ml-auto h-4 w-4 opacity-40" />}{collapsed && item.to === '/app/processing' && activeJobs > 0 && <span className="absolute right-2 top-2 h-2.5 w-2.5 rounded-full bg-[var(--color-brand-500)] ring-2 ring-[var(--color-sidebar-bg)]" />}</NavLink>; })}</div>;
}

function Divider({ collapsed, label }: { collapsed: boolean; label: string }) {
  if (collapsed) return <div className="my-4 h-px" style={{ backgroundColor: 'var(--color-border)' }} />;
  return <div className="px-3 pb-1 pt-5 text-[0.65rem] font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-text-muted)' }}>{label}</div>;
}

function navClass(isActive: boolean, collapsed: boolean) {
  const base = collapsed ? 'group relative flex min-h-11 items-center justify-center rounded-2xl transition' : 'group flex min-h-11 items-center gap-3 rounded-2xl px-3 text-sm font-medium transition';
  return `${base} ${isActive ? 'bg-[var(--color-nav-active)] text-[var(--color-brand-600)] dark:text-[var(--color-brand-400)]' : 'text-[var(--color-text-secondary)] hover:bg-[var(--color-nav-hover)] hover:text-[var(--color-text-primary)]'}`;
}
