import { lazy, Suspense, useEffect, useState, type ComponentType } from 'react';
import { Link, NavLink, Outlet } from 'react-router-dom';
import {
  Activity,
  BookOpen,
  Boxes,
  ChevronRight,
  Code2,
  FileText,
  FolderOpen,
  Home,
  Library,
  ListTodo,
  Menu,
  Mic,
  PanelLeftClose,
  PanelLeftOpen,
  Settings,
  X,
} from 'lucide-react';
import { useAuthContext } from '../contexts/useAuthContext';
import { getHealth, getLibraryStats } from '../lib/api';

const CLERK_CONFIGURED = Boolean(
  import.meta.env.VITE_CLERK_PUBLISHABLE_KEY && import.meta.env.VITE_CLERK_PUBLISHABLE_KEY !== 'YOUR_PUBLISHABLE_KEY'
);
const LazyClerkUserButton = CLERK_CONFIGURED
  ? lazy(() => import('./ClerkUserButton').then((m) => ({ default: m.ClerkUserButton })))
  : null;

const SIDEBAR_COLLAPSED_KEY = 'mta-app-sidebar-collapsed';
const LIBRARY_STATS_POLL_INTERVAL_MS = 8000;

type NavItem = {
  label: string;
  to: string;
  icon: ComponentType<{ className?: string }>;
  end?: boolean;
};

const primaryNav: NavItem[] = [
  { label: 'Dashboard', to: '/app', icon: Home, end: true },
  { label: 'Processing', to: '/app/processing', icon: ListTodo },
  { label: 'Video', to: '/app/video', icon: FileText },
  { label: 'Recordings', to: '/app/audio', icon: Mic },
  { label: 'PDF', to: '/app/pdf', icon: BookOpen },
  { label: 'Library', to: '/app/library', icon: Library },
  { label: 'Collections', to: '/app/collections', icon: FolderOpen },
];

const developerNav: NavItem[] = [
  { label: 'Developer', to: '/app/developer', icon: Code2, end: true },
  { label: 'Webhooks', to: '/app/developer/webhooks', icon: Boxes },
];

const opsNav: NavItem = { label: 'Ops Health', to: '/app/admin/ops', icon: Activity };

export function AppShell() {
  const [mobileOpen, setMobileOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === 'true'; } catch { return false; }
  });
  const { user, isClerkEnabled } = useAuthContext();
  const [activeJobs, setActiveJobs] = useState(0);

  useEffect(() => {
    let current = true;
    let refreshing = false;
    let timer: number | undefined;

    const clearScheduledRefresh = () => {
      if (timer !== undefined) {
        window.clearTimeout(timer);
        timer = undefined;
      }
    };

    const scheduleRefresh = () => {
      clearScheduledRefresh();
      if (current && document.visibilityState === 'visible') {
        timer = window.setTimeout(() => { void refresh(); }, LIBRARY_STATS_POLL_INTERVAL_MS);
      }
    };

    const refresh = async () => {
      clearScheduledRefresh();
      if (!current || refreshing || document.visibilityState !== 'visible') return;

      refreshing = true;
      try {
        const stats = await getLibraryStats();
        if (current) setActiveJobs(stats.pending + stats.processing);
      } catch {
        // The navigation remains usable if the lightweight status check fails.
      } finally {
        refreshing = false;
        scheduleRefresh();
      }
    };

    const handleVisibilityChange = () => {
      // Even a browser-throttled request every minute prevents Neon from
      // autosuspending. Resume with an immediate refresh when the user returns.
      if (document.visibilityState === 'visible') {
        void refresh();
      } else {
        clearScheduledRefresh();
      }
    };

    void getHealth().catch(() => undefined);
    document.addEventListener('visibilitychange', handleVisibilityChange);
    if (document.visibilityState === 'visible') void refresh();

    return () => {
      current = false;
      clearScheduledRefresh();
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, []);

  const toggleCollapsed = () => {
    setCollapsed((current) => {
      const next = !current;
      try { localStorage.setItem(SIDEBAR_COLLAPSED_KEY, String(next)); } catch { /* ignore */ }
      return next;
    });
  };

  return (
    <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)', color: 'var(--color-text-primary)' }}>
      <aside className={`fixed inset-y-0 left-0 z-40 hidden border-r backdrop-blur-xl transition-[width] duration-200 xl:flex xl:flex-col ${collapsed ? 'w-20' : 'w-72'}`} style={{ backgroundColor: 'var(--color-sidebar-bg)', borderColor: 'var(--color-border)' }}>
        <SidebarContent collapsed={collapsed} onToggleCollapsed={toggleCollapsed} userName={user?.name || user?.email || 'Media workspace'} isClerkEnabled={isClerkEnabled} activeJobs={activeJobs} />
      </aside>

      {mobileOpen && (
        <div className="fixed inset-0 z-50 xl:hidden" role="dialog" aria-modal="true">
          <button className="absolute inset-0 bg-black/55" aria-label="Close navigation" onClick={() => setMobileOpen(false)} />
          <aside className="absolute inset-y-0 left-0 flex w-[86vw] max-w-[340px] flex-col border-r" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
            <SidebarContent collapsed={false} onToggleCollapsed={toggleCollapsed} userName={user?.name || user?.email || 'Media workspace'} isClerkEnabled={isClerkEnabled} activeJobs={activeJobs} mobile onNavigate={() => setMobileOpen(false)} />
          </aside>
          <button className="absolute left-[calc(min(86vw,340px)+0.75rem)] top-4 flex h-11 w-11 items-center justify-center rounded-full border bg-white/10 text-white backdrop-blur" style={{ borderColor: 'rgba(255,255,255,0.25)' }} onClick={() => setMobileOpen(false)} aria-label="Close navigation">
            <X className="h-5 w-5" />
          </button>
        </div>
      )}

      <div className={`transition-[padding] duration-200 ${collapsed ? 'xl:pl-20' : 'xl:pl-72'}`}>
        <header className="sticky top-0 z-30 border-b backdrop-blur-xl" style={{ backgroundColor: 'var(--color-header-bg)', borderColor: 'var(--color-border)' }}>
          <div className="flex h-16 items-center justify-between gap-3 px-4 sm:px-6">
            <button className="inline-flex h-11 w-11 items-center justify-center rounded-xl border transition-colors hover:bg-[var(--color-nav-hover)] xl:hidden" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={() => setMobileOpen(true)} aria-label="Open navigation">
              <Menu className="h-5 w-5" />
            </button>
            <div className="min-w-0">
              <p className="text-xs font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-text-muted)' }}>Media Tools</p>
              <p className="hidden truncate text-sm sm:block" style={{ color: 'var(--color-text-secondary)' }}>Capture, summarize, organize, and chat with media.</p>
            </div>
            <div className="flex items-center gap-2">
              {activeJobs > 0 && <Link to="/app/processing" className="hidden min-h-11 items-center gap-2 rounded-xl border px-3 text-xs font-semibold sm:inline-flex" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}><span className="relative flex h-2.5 w-2.5"><span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-[var(--color-brand-500)] opacity-50" /><span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-[var(--color-brand-500)]" /></span>{activeJobs} active</Link>}
              <details className="group relative hidden sm:block">
                <summary className="flex min-h-11 cursor-pointer list-none items-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition hover:opacity-90" style={{ backgroundColor: 'var(--color-brand-500)' }}>
                  <FileText className="h-4 w-4" />
                  New
                  <ChevronRight className="h-4 w-4 rotate-90 transition-transform group-open:-rotate-90" />
                </summary>
                <div className="absolute right-0 top-[calc(100%+0.5rem)] z-50 w-56 rounded-2xl border p-2 shadow-2xl" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
                  <NewItemLink to="/app/video" icon={FileText} label="Video transcript" />
                  <NewItemLink to="/app/audio" icon={Mic} label="Recording or audio" />
                  <NewItemLink to="/app/pdf" icon={BookOpen} label="PDF document" />
                </div>
              </details>
              {LazyClerkUserButton && (
                <Suspense fallback={<div className="h-11 w-11 rounded-full" style={{ backgroundColor: 'var(--color-surface-overlay)' }} />}>
                  <LazyClerkUserButton />
                </Suspense>
              )}
            </div>
          </div>
        </header>

        <main className="min-h-[calc(100vh-4rem)] px-4 py-5 sm:px-6 sm:py-7 xl:px-8">
          <Outlet />
        </main>
      </div>
    </div>
  );
}

function NewItemLink({ to, icon: Icon, label }: { to: string; icon: ComponentType<{ className?: string }>; label: string }) {
  return (
    <Link to={to} className="flex min-h-11 items-center gap-3 rounded-xl px-3 text-sm font-medium transition hover:bg-[var(--color-nav-hover)]">
      <Icon className="h-4 w-4 text-[var(--color-brand-500)]" />
      {label}
    </Link>
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
        <Link to="/app" onClick={onNavigate} className="flex min-h-11 items-center gap-3 rounded-2xl focus-visible:outline-none">
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-500)' }}>
            <FileText className="h-5 w-5 text-white" />
          </div>
          {!collapsed && (
            <div className="min-w-0">
              <p className="truncate text-base font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>Media Tools</p>
              <p className="truncate text-xs" style={{ color: 'var(--color-text-muted)' }}>Private workspace</p>
            </div>
          )}
        </Link>
        {!mobile && !collapsed && (
          <button className="ml-auto hidden h-11 w-11 items-center justify-center rounded-xl border text-sm transition-colors hover:bg-[var(--color-nav-hover)] xl:flex" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={onToggleCollapsed} aria-label="Collapse sidebar">
            <PanelLeftClose className="h-4 w-4" />
          </button>
        )}
      </div>

      {!mobile && collapsed && (
        <button className="mx-auto mt-3 flex h-11 w-11 items-center justify-center rounded-xl border" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={onToggleCollapsed} aria-label="Expand sidebar">
          <PanelLeftOpen className="h-4 w-4" />
        </button>
      )}

      <nav className="mt-5 flex flex-1 flex-col gap-1 overflow-y-auto">
        <NavSection items={primaryNav} collapsed={collapsed} onNavigate={onNavigate} activeJobs={activeJobs} />
        <Divider collapsed={collapsed} label="Developer" />
        <NavSection items={isClerkEnabled ? developerNav : [...developerNav, opsNav]} collapsed={collapsed} onNavigate={onNavigate} />
      </nav>

      <div className={`mt-4 border-t pt-4 ${collapsed ? 'px-0' : 'px-2'}`} style={{ borderColor: 'var(--color-border)' }}>
        <NavLink to="/app/settings" onClick={onNavigate} className={({ isActive }) => navClass(isActive, collapsed)} title="Settings">
          <Settings className="h-5 w-5 shrink-0" />
          {!collapsed && <span>Settings</span>}
        </NavLink>
        {!collapsed && (
          <div className="mt-4 rounded-2xl border p-3" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
            <p className="truncate text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>{userName}</p>
            <p className="mt-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>{isClerkEnabled ? 'Signed in with Clerk' : 'API key development mode'}</p>
          </div>
        )}
      </div>
    </div>
  );
}

function NavSection({ items, collapsed, onNavigate, activeJobs = 0 }: { items: NavItem[]; collapsed: boolean; onNavigate?: () => void; activeJobs?: number }) {
  return (
    <div className="space-y-1">
      {items.map((item) => {
        const Icon = item.icon;
        return (
          <NavLink key={item.to} to={item.to} end={item.end} onClick={onNavigate} className={({ isActive }) => navClass(isActive, collapsed)} title={collapsed ? item.label : undefined}>
            <Icon className="h-5 w-5 shrink-0" />
            {!collapsed && <span>{item.label}</span>}
            {!collapsed && item.to === '/app/processing' && activeJobs > 0 && <span className="ml-auto rounded-full px-2 py-0.5 text-xs font-semibold" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>{activeJobs}</span>}
            {!collapsed && !(item.to === '/app/processing' && activeJobs > 0) && <ChevronRight className="ml-auto h-4 w-4 opacity-50" />}
            {collapsed && item.to === '/app/processing' && activeJobs > 0 && <span className="absolute right-2 top-2 h-2.5 w-2.5 rounded-full bg-[var(--color-brand-500)] ring-2 ring-[var(--color-sidebar-bg)]" />}
          </NavLink>
        );
      })}
    </div>
  );
}

function Divider({ collapsed, label }: { collapsed: boolean; label: string }) {
  if (collapsed) {
    return <div className="my-4 h-px" style={{ backgroundColor: 'var(--color-border)' }} />;
  }
  return (
    <div className="px-3 pb-1 pt-5 text-[0.65rem] font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-text-muted)' }}>
      {label}
    </div>
  );
}

function navClass(isActive: boolean, collapsed: boolean) {
  const base = collapsed
    ? 'group relative flex min-h-11 items-center justify-center rounded-2xl transition'
    : 'group flex min-h-11 items-center gap-3 rounded-2xl px-3 text-sm font-medium transition';

	return `${base} ${isActive ? 'bg-[var(--color-brand-500)] text-white shadow-lg shadow-black/15' : 'text-[var(--color-text-secondary)] hover:bg-[var(--color-nav-hover)] hover:text-[var(--color-text-primary)]'}`;
}
