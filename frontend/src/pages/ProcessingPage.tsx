import { useCallback, useEffect, useMemo, useState, type ComponentType, type CSSProperties } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { AlertCircle, ArrowRight, CheckCircle2, Clock3, Loader2, RefreshCw, RotateCcw } from 'lucide-react';
import { useLibraryActivity } from '../contexts/useLibraryActivity';
import { getErrorMessage, listLibraryItems, type LibraryItem } from '../lib/api';
import { itemDetailPath, itemTypeLabel } from '../lib/library';

type JobFilter = 'active' | 'failed' | 'completed';

export function ProcessingPage() {
  const [searchParams, setSearchParams] = useSearchParams();
  const requested = searchParams.get('status');
  const activeFilter: JobFilter = requested === 'failed' || requested === 'completed' ? requested : 'active';
  const {
    activeItems,
    isLoading: isActivityLoading,
    error: activityError,
    refresh: refreshActivity,
  } = useLibraryActivity();
  const [filteredItems, setFilteredItems] = useState<LibraryItem[]>([]);
  const [isFilteredLoading, setIsFilteredLoading] = useState(false);
  const [filteredError, setFilteredError] = useState('');

  const loadJobs = useCallback(async () => {
    if (activeFilter === 'active') {
      await refreshActivity(true);
      return;
    }
    setIsFilteredLoading(true);
    setFilteredError('');
    try {
      const result = await listLibraryItems({ status: activeFilter, per_page: 100 });
      setFilteredItems(result.data);
    } catch (err) {
      setFilteredError(getErrorMessage(err));
    } finally {
      setIsFilteredLoading(false);
    }
  }, [activeFilter, refreshActivity]);

  useEffect(() => {
    if (activeFilter !== 'active') void loadJobs();
  }, [activeFilter, loadJobs]);

  const items = activeFilter === 'active' ? activeItems : filteredItems;
  const isLoading = activeFilter === 'active' ? isActivityLoading : isFilteredLoading;
  const error = activeFilter === 'active' ? activityError : filteredError;

  const counts = useMemo(() => ({
    pending: items.filter((item) => item.status === 'pending').length,
    processing: items.filter((item) => item.status === 'processing').length,
    failed: activeFilter === 'failed' ? items.length : 0,
  }), [activeFilter, items]);

  return (
    <div className="mx-auto max-w-6xl space-y-7">
      <header className="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
        <div>
          <div className="mb-3 inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.18em]" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
            <Clock3 className="h-3.5 w-3.5" /> Job activity
          </div>
          <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Processing center</h1>
          <p className="mt-2 max-w-2xl text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>See what is queued, follow work in progress, and resolve failed media without wondering whether a job is still moving.</p>
        </div>
        <button onClick={() => void loadJobs()} disabled={isLoading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold disabled:opacity-50" style={{ borderColor: 'var(--color-border)' }}>
          <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} /> Refresh
        </button>
      </header>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat label="Queued" value={counts.pending} icon={Clock3} />
        <Stat label="In progress" value={counts.processing} icon={Loader2} />
        <Stat label="Needs attention" value={counts.failed} icon={AlertCircle} className="col-span-2 sm:col-span-1" />
      </div>

      <div className="grid grid-cols-3 gap-1 rounded-2xl p-1" style={{ backgroundColor: 'var(--color-surface-elevated)' }}>
        {(['active', 'failed', 'completed'] as JobFilter[]).map((filter) => (
          <button key={filter} onClick={() => setSearchParams(filter === 'active' ? {} : { status: filter })} className="min-h-11 min-w-0 rounded-xl px-2 text-xs font-semibold capitalize sm:px-4 sm:text-sm" style={{ backgroundColor: filter === activeFilter ? 'var(--color-surface)' : 'transparent', color: filter === activeFilter ? 'var(--color-text-primary)' : 'var(--color-text-muted)' }}>{filter === 'active' ? 'Active jobs' : filter}</button>
        ))}
      </div>

      {error && <div role="alert" className="rounded-2xl border p-4 text-sm" style={{ borderColor: 'var(--color-danger)', color: 'var(--color-danger)' }}>{error}</div>}

      <section className="overflow-hidden rounded-[2rem] border" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        {isLoading ? (
          <div className="flex min-h-64 items-center justify-center gap-3" style={{ color: 'var(--color-text-secondary)' }}><Loader2 className="h-5 w-5 animate-spin" /> Loading jobs…</div>
        ) : items.length === 0 ? (
          <div className="px-6 py-16 text-center">
            <CheckCircle2 className="mx-auto h-9 w-9" style={{ color: 'var(--color-success)' }} />
            <h2 className="mt-4 font-semibold">{activeFilter === 'failed' ? 'No failed jobs' : activeFilter === 'active' ? 'Nothing is processing' : 'No completed jobs yet'}</h2>
            <p className="mx-auto mt-2 max-w-md text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{activeFilter === 'failed' ? 'Your workspace has no media that needs attention.' : 'New video, audio, and document jobs will appear here automatically.'}</p>
          </div>
        ) : (
          <div className="divide-y" style={{ borderColor: 'var(--color-border)' }}>
            {items.map((item) => <JobRow key={`${item.item_type}-${item.id}`} item={item} />)}
          </div>
        )}
      </section>
    </div>
  );
}

function Stat({ label, value, icon: Icon, className = '' }: { label: string; value: number; icon: ComponentType<{ className?: string; style?: CSSProperties }>; className?: string }) {
  return <div className={`rounded-2xl border p-4 sm:p-5 ${className}`} style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}><div className="flex items-center justify-between gap-3"><div><p className="text-xs sm:text-sm" style={{ color: 'var(--color-text-secondary)' }}>{label}</p><p className="mt-1 text-2xl font-semibold">{value}</p></div><Icon className="h-5 w-5" style={{ color: 'var(--color-brand-500)' }} /></div></div>;
}

function JobRow({ item }: { item: LibraryItem }) {
  const isFailed = item.status === 'failed';
  return (
    <Link to={itemDetailPath(item.item_type, item.id)} className="flex min-h-20 items-center justify-between gap-4 px-5 py-4 transition hover:bg-[var(--color-nav-hover)] sm:px-6">
      <div className="min-w-0">
        <div className="mb-1 flex flex-wrap items-center gap-2"><span className="text-xs font-semibold uppercase tracking-wider" style={{ color: 'var(--color-text-muted)' }}>{itemTypeLabel(item.item_type)}</span><span className="rounded-full px-2 py-0.5 text-xs font-semibold capitalize" style={{ backgroundColor: 'var(--color-surface-subtle)', color: isFailed ? 'var(--color-danger)' : item.status === 'completed' ? 'var(--color-success)' : 'var(--color-warning)' }}>{item.status}</span></div>
        <p className="truncate text-sm font-semibold">{item.title}</p>
        <p className="mt-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>{isFailed ? 'Open this item to see the error and retry options.' : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(item.created_at))}</p>
      </div>
      {isFailed ? <RotateCcw className="h-4 w-4 shrink-0" style={{ color: 'var(--color-danger)' }} /> : <ArrowRight className="h-4 w-4 shrink-0" style={{ color: 'var(--color-text-muted)' }} />}
    </Link>
  );
}
