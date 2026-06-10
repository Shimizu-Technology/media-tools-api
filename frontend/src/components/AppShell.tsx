import { lazy, Suspense, useState, type ComponentType } from 'react';
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
  Menu,
  Mic,
  PanelLeftClose,
  PanelLeftOpen,
  Settings,
  X,
} from 'lucide-react';
import { useAuthContext } from '../contexts/useAuthContext';

const CLERK_CONFIGURED = Boolean(
  import.meta.env.VITE_CLERK_PUBLISHABLE_KEY && import.meta.env.VITE_CLERK_PUBLISHABLE_KEY !== 'YOUR_PUBLISHABLE_KEY'
);
const LazyClerkUserButton = CLERK_CONFIGURED
  ? lazy(() => import('./ClerkUserButton').then((m) => ({ default: m.ClerkUserButton })))
  : null;

const SIDEBAR_COLLAPSED_KEY = 'mta-app-sidebar-collapsed';

type NavItem = {
  label: string;
  to: string;
  icon: ComponentType<{ className?: string }>;
  end?: boolean;
};

const primaryNav: NavItem[] = [
  { label: 'Dashboard', to: '/app', icon: Home, end: true },
  { label: 'Video', to: '/app/video', icon: FileText },
  { label: 'Recordings', to: '/app/audio', icon: Mic },
  { label: 'PDF', to: '/app/pdf', icon: BookOpen },
  { label: 'Library', to: '/app/library', icon: Library },
  { label: 'Collections', to: '/app/collections', icon: FolderOpen },
];

const developerNav: NavItem[] = [
  { label: 'Developer', to: '/app/developer', icon: Code2, end: true },
  { label: 'Webhooks', to: '/app/developer/webhooks', icon: Boxes },
  { label: 'Ops Health', to: '/app/admin/ops', icon: Activity },
];

export function AppShell() {
  const [mobileOpen, setMobileOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === 'true'; } catch { return false; }
  });
  const { user, isClerkEnabled } = useAuthContext();

  const toggleCollapsed = () => {
    setCollapsed((current) => {
      const next = !current;
      try { localStorage.setItem(SIDEBAR_COLLAPSED_KEY, String(next)); } catch { /* ignore */ }
      return next;
    });
  };

  return (
    <div className="min-h-screen" style={{ backgroundColor: 'var(--color-surface)', color: 'var(--color-text-primary)' }}>
      <aside className={`fixed inset-y-0 left-0 z-40 hidden border-r backdrop-blur-xl transition-[width] duration-200 lg:flex lg:flex-col ${collapsed ? 'w-20' : 'w-72'}`} style={{ backgroundColor: 'rgba(15, 18, 23, 0.92)', borderColor: 'var(--color-border)' }}>
        <SidebarContent collapsed={collapsed} onToggleCollapsed={toggleCollapsed} userName={user?.name || user?.email || 'Media workspace'} isClerkEnabled={isClerkEnabled} />
      </aside>

      {mobileOpen && (
        <div className="fixed inset-0 z-50 lg:hidden" role="dialog" aria-modal="true">
          <button className="absolute inset-0 bg-black/55" aria-label="Close navigation" onClick={() => setMobileOpen(false)} />
          <aside className="absolute inset-y-0 left-0 flex w-[86vw] max-w-[340px] flex-col border-r" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
            <SidebarContent collapsed={false} onToggleCollapsed={toggleCollapsed} userName={user?.name || user?.email || 'Media workspace'} isClerkEnabled={isClerkEnabled} mobile onNavigate={() => setMobileOpen(false)} />
          </aside>
          <button className="absolute left-[calc(min(86vw,340px)+0.75rem)] top-4 flex h-10 w-10 items-center justify-center rounded-full border bg-white/10 text-white backdrop-blur" style={{ borderColor: 'rgba(255,255,255,0.25)' }} onClick={() => setMobileOpen(false)} aria-label="Close navigation">
            <X className="h-5 w-5" />
          </button>
        </div>
      )}

      <div className={`transition-[padding] duration-200 ${collapsed ? 'lg:pl-20' : 'lg:pl-72'}`}>
        <header className="sticky top-0 z-30 border-b backdrop-blur-xl" style={{ backgroundColor: 'rgba(11, 13, 16, 0.82)', borderColor: 'var(--color-border)' }}>
          <div className="flex h-16 items-center justify-between gap-3 px-4 sm:px-6">
            <button className="inline-flex h-11 w-11 items-center justify-center rounded-xl border lg:hidden" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={() => setMobileOpen(true)} aria-label="Open navigation">
              <Menu className="h-5 w-5" />
            </button>
            <div className="min-w-0">
              <p className="text-xs font-semibold uppercase tracking-[0.22em]" style={{ color: 'var(--color-text-muted)' }}>Media Tools</p>
              <p className="truncate text-sm" style={{ color: 'var(--color-text-secondary)' }}>Capture, summarize, organize, and chat with media.</p>
            </div>
            <div className="flex items-center gap-2">
              <Link to="/app/video" className="hidden min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition hover:opacity-90 sm:inline-flex" style={{ backgroundColor: 'var(--color-brand-500)' }}>
                <FileText className="h-4 w-4" />
                New transcript
              </Link>
              {LazyClerkUserButton && (
                <Suspense fallback={<div className="h-9 w-9 rounded-full" style={{ backgroundColor: 'var(--color-surface-overlay)' }} />}>
                  <LazyClerkUserButton />
                </Suspense>
              )}
            </div>
          </div>
        </header>

        <main className="min-h-[calc(100vh-4rem)] px-4 py-6 sm:px-6 lg:px-8">
          <Outlet />
        </main>
      </div>
    </div>
  );
}

function SidebarContent({ collapsed, onToggleCollapsed, userName, isClerkEnabled, mobile = false, onNavigate }: {
  collapsed: boolean;
  onToggleCollapsed: () => void;
  userName: string;
  isClerkEnabled: boolean;
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
          <button className="ml-auto hidden h-10 w-10 items-center justify-center rounded-xl border text-sm lg:flex" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={onToggleCollapsed} aria-label="Collapse sidebar">
            <PanelLeftClose className="h-4 w-4" />
          </button>
        )}
      </div>

      {!mobile && collapsed && (
        <button className="mx-auto mt-3 flex h-10 w-10 items-center justify-center rounded-xl border" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }} onClick={onToggleCollapsed} aria-label="Expand sidebar">
          <PanelLeftOpen className="h-4 w-4" />
        </button>
      )}

      <nav className="mt-5 flex flex-1 flex-col gap-1 overflow-y-auto">
        <NavSection items={primaryNav} collapsed={collapsed} onNavigate={onNavigate} />
        <Divider collapsed={collapsed} label="Developer" />
        <NavSection items={developerNav} collapsed={collapsed} onNavigate={onNavigate} />
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

function NavSection({ items, collapsed, onNavigate }: { items: NavItem[]; collapsed: boolean; onNavigate?: () => void }) {
  return (
    <div className="space-y-1">
      {items.map((item) => {
        const Icon = item.icon;
        return (
          <NavLink key={item.to} to={item.to} end={item.end} onClick={onNavigate} className={({ isActive }) => navClass(isActive, collapsed)} title={collapsed ? item.label : undefined}>
            <Icon className="h-5 w-5 shrink-0" />
            {!collapsed && <span>{item.label}</span>}
            {!collapsed && <ChevronRight className="ml-auto h-4 w-4 opacity-50" />}
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
    ? 'group flex min-h-11 items-center justify-center rounded-2xl transition'
    : 'group flex min-h-11 items-center gap-3 rounded-2xl px-3 text-sm font-medium transition';

  return `${base} ${isActive ? 'bg-[var(--color-brand-500)] text-white shadow-lg shadow-black/15' : 'text-[var(--color-text-secondary)] hover:bg-white/[0.06] hover:text-[var(--color-text-primary)]'}`;
}
