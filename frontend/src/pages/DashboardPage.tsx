import { useEffect, useMemo, useState, type ComponentType, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import {
  AlertCircle,
  ArrowRight,
  BookOpen,
  CheckCircle2,
  Clock3,
  FileText,
  FolderOpen,
  Library,
  Loader2,
  Mic,
  Plus,
  Sparkles,
} from 'lucide-react';
import {
  listAudioTranscriptions,
  listCollections,
  listPDFExtractions,
  listTranscripts,
  type AudioTranscription,
  type Collection,
  type PDFExtraction,
  type Transcript,
} from '../lib/api';
import { useAuthContext } from '../contexts/useAuthContext';

type DashboardState = {
  transcripts: Transcript[];
  audio: AudioTranscription[];
  pdfs: PDFExtraction[];
  collections: Collection[];
};

const emptyState: DashboardState = {
  transcripts: [],
  audio: [],
  pdfs: [],
  collections: [],
};

type RecentItem = {
  id: string;
  type: 'Video' | 'Recording' | 'PDF';
  title: string;
  status: string;
  createdAt: string;
  href: string;
};

export function DashboardPage() {
  const { user } = useAuthContext();
  const [data, setData] = useState<DashboardState>(emptyState);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    let isMounted = true;

    async function loadDashboard() {
      setIsLoading(true);
      setError('');
      const [transcriptsResult, audioResult, pdfsResult, collectionsResult] = await Promise.allSettled([
        listTranscripts({ per_page: 12 }),
        listAudioTranscriptions(),
        listPDFExtractions(),
        listCollections(),
      ]);

      if (!isMounted) return;

      if (transcriptsResult.status === 'fulfilled' || audioResult.status === 'fulfilled' || pdfsResult.status === 'fulfilled') {
        setData({
          transcripts: transcriptsResult.status === 'fulfilled' ? transcriptsResult.value.data : [],
          audio: audioResult.status === 'fulfilled' ? audioResult.value : [],
          pdfs: pdfsResult.status === 'fulfilled' ? pdfsResult.value : [],
          collections: collectionsResult.status === 'fulfilled' ? collectionsResult.value : [],
        });
      } else {
        setError('Could not load your workspace yet. Try refreshing in a moment.');
        setData(emptyState);
      }
      setIsLoading(false);
    }

    void loadDashboard();
    return () => { isMounted = false; };
  }, []);

  const totals = useMemo(() => {
    const allItems = [...data.transcripts, ...data.audio, ...data.pdfs];
    const processing = allItems.filter((item) => item.status === 'pending' || item.status === 'processing').length;
    const failed = allItems.filter((item) => item.status === 'failed').length;
    const completed = allItems.filter((item) => item.status === 'completed').length;
    return { total: allItems.length, processing, failed, completed };
  }, [data]);

  const recentItems = useMemo<RecentItem[]>(() => {
    const transcriptItems = data.transcripts.map((item) => ({
      id: item.id,
      type: 'Video' as const,
      title: item.title || item.youtube_url || 'Video transcript',
      status: item.status,
      createdAt: item.created_at,
      href: `/app/video?id=${item.id}`,
    }));
    const audioItems = data.audio.map((item) => ({
      id: item.id,
      type: 'Recording' as const,
      title: item.original_name || item.filename || 'Audio transcription',
      status: item.status,
      createdAt: item.created_at,
      href: `/app/audio?id=${item.id}`,
    }));
    const pdfItems = data.pdfs.map((item) => ({
      id: item.id,
      type: 'PDF' as const,
      title: item.original_name || item.filename || 'PDF extraction',
      status: item.status,
      createdAt: item.created_at,
      href: `/app/pdf?id=${item.id}`,
    }));

    return [...transcriptItems, ...audioItems, ...pdfItems]
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
      .slice(0, 6);
  }, [data]);

  return (
    <div className="mx-auto max-w-7xl space-y-8">
      <section className="grid gap-6 lg:grid-cols-[1.35fr_0.65fr]">
        <div className="rounded-[2rem] border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <div className="inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.2em]" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
            <Sparkles className="h-3.5 w-3.5" />
            Workspace
          </div>
          <h1 className="mt-5 max-w-2xl text-3xl font-semibold tracking-tight sm:text-5xl" style={{ color: 'var(--color-text-primary)' }}>
            Welcome back{user?.name ? `, ${user.name.split(' ')[0]}` : ''}.
          </h1>
          <p className="mt-4 max-w-2xl text-base leading-7" style={{ color: 'var(--color-text-secondary)' }}>
            Turn videos, meetings, voice notes, and PDFs into searchable library items with summaries, collections, and chat.
          </p>
          <div className="mt-7 flex flex-wrap gap-3">
            <QuickAction to="/app/video" icon={FileText} label="New video transcript" primary />
            <QuickAction to="/app/audio" icon={Mic} label="Record or upload audio" />
            <QuickAction to="/app/pdf" icon={BookOpen} label="Extract PDF" />
          </div>
        </div>

        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-1">
          <MetricCard label="Library items" value={totals.total} icon={Library} />
          <MetricCard label="Processing" value={totals.processing} icon={Clock3} tone="warning" />
          <MetricCard label="Completed" value={totals.completed} icon={CheckCircle2} tone="success" />
          <MetricCard label="Needs attention" value={totals.failed} icon={AlertCircle} tone="danger" />
        </div>
      </section>

      {error && (
        <div className="rounded-2xl border px-4 py-3 text-sm" style={{ borderColor: 'var(--color-danger)', color: 'var(--color-danger)', backgroundColor: 'rgba(239, 68, 68, 0.08)' }}>
          {error}
        </div>
      )}

      <section className="grid gap-6 lg:grid-cols-[1fr_0.72fr]">
        <Panel title="Recent library items" action={<Link to="/app/library" className="inline-flex items-center gap-1 text-sm font-semibold" style={{ color: 'var(--color-brand-500)' }}>View library <ArrowRight className="h-4 w-4" /></Link>}>
          {isLoading ? (
            <LoadingRows />
          ) : recentItems.length > 0 ? (
            <div className="divide-y" style={{ borderColor: 'var(--color-border)' }}>
              {recentItems.map((item) => <RecentItemRow key={`${item.type}-${item.id}`} item={item} />)}
            </div>
          ) : (
            <EmptyPanel icon={Library} title="No media yet" body="Start with a video, recording, or PDF. Everything you process will appear here." />
          )}
        </Panel>

        <Panel title="Collections" action={<Link to="/app/collections" className="inline-flex items-center gap-1 text-sm font-semibold" style={{ color: 'var(--color-brand-500)' }}>Manage <ArrowRight className="h-4 w-4" /></Link>}>
          {isLoading ? (
            <LoadingRows compact />
          ) : data.collections.length > 0 ? (
            <div className="space-y-3">
              {data.collections.slice(0, 5).map((collection) => (
                <Link key={collection.id} to={`/app/collections/${collection.id}`} className="flex items-center justify-between rounded-2xl border p-4 transition hover:-translate-y-0.5" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
                  <div className="flex min-w-0 items-center gap-3">
                    <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl" style={{ backgroundColor: 'var(--color-surface-overlay)', color: 'var(--color-brand-500)' }}>
                      <FolderOpen className="h-4 w-4" />
                    </div>
                    <div className="min-w-0">
                      <p className="truncate text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>{collection.name}</p>
                      <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>{collection.item_count} items</p>
                    </div>
                  </div>
                  <ArrowRight className="h-4 w-4 shrink-0" style={{ color: 'var(--color-text-muted)' }} />
                </Link>
              ))}
            </div>
          ) : (
            <EmptyPanel icon={FolderOpen} title="Create your first collection" body="Group transcripts, recordings, and PDFs by client, topic, or project." />
          )}
        </Panel>
      </section>
    </div>
  );
}

function QuickAction({ to, icon: Icon, label, primary = false }: { to: string; icon: ComponentType<{ className?: string }>; label: string; primary?: boolean }) {
  return (
    <Link
      to={to}
      className={`inline-flex min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold transition hover:-translate-y-0.5 ${primary ? 'text-white' : ''}`}
      style={{
        backgroundColor: primary ? 'var(--color-brand-500)' : 'var(--color-surface-subtle)',
        color: primary ? '#fff' : 'var(--color-text-primary)',
        border: primary ? '1px solid transparent' : '1px solid var(--color-border)',
      }}
    >
      {primary ? <Plus className="h-4 w-4" /> : <Icon className="h-4 w-4" />}
      {label}
    </Link>
  );
}

function MetricCard({ label, value, icon: Icon, tone = 'default' }: { label: string; value: number; icon: ComponentType<{ className?: string }>; tone?: 'default' | 'warning' | 'success' | 'danger' }) {
  const colors = {
    default: 'var(--color-brand-500)',
    warning: 'var(--color-warning)',
    success: 'var(--color-success)',
    danger: 'var(--color-danger)',
  };

  return (
    <div className="rounded-3xl border p-5" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
      <div className="flex items-center justify-between gap-4">
        <div>
          <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>{label}</p>
          <p className="mt-2 text-3xl font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>{value}</p>
        </div>
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-surface-subtle)', color: colors[tone] }}>
          <Icon className="h-5 w-5" />
        </div>
      </div>
    </div>
  );
}

function Panel({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section className="rounded-[2rem] border p-5 sm:p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
      <div className="mb-5 flex items-center justify-between gap-4">
        <h2 className="text-lg font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>{title}</h2>
        {action}
      </div>
      {children}
    </section>
  );
}

function RecentItemRow({ item }: { item: RecentItem }) {
  return (
    <Link to={item.href} className="flex items-center justify-between gap-4 py-4 transition hover:translate-x-1">
      <div className="min-w-0">
        <div className="mb-1 flex items-center gap-2">
          <span className="rounded-full px-2 py-0.5 text-xs font-semibold" style={{ backgroundColor: 'var(--color-surface-subtle)', color: 'var(--color-text-secondary)' }}>{item.type}</span>
          <StatusBadge status={item.status} />
        </div>
        <p className="truncate text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>{item.title}</p>
        <p className="mt-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>{formatDate(item.createdAt)}</p>
      </div>
      <ArrowRight className="h-4 w-4 shrink-0" style={{ color: 'var(--color-text-muted)' }} />
    </Link>
  );
}

function StatusBadge({ status }: { status: string }) {
  const tone = status === 'completed' ? 'var(--color-success)' : status === 'failed' ? 'var(--color-danger)' : 'var(--color-warning)';
  return <span className="rounded-full px-2 py-0.5 text-xs font-semibold capitalize" style={{ backgroundColor: 'var(--color-surface-subtle)', color: tone }}>{status}</span>;
}

function EmptyPanel({ icon: Icon, title, body }: { icon: ComponentType<{ className?: string }>; title: string; body: string }) {
  return (
    <div className="rounded-3xl border border-dashed p-8 text-center" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
      <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-surface-overlay)', color: 'var(--color-brand-500)' }}>
        <Icon className="h-5 w-5" />
      </div>
      <p className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>{title}</p>
      <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{body}</p>
    </div>
  );
}

function LoadingRows({ compact = false }: { compact?: boolean }) {
  return (
    <div className="space-y-3">
      {Array.from({ length: compact ? 3 : 5 }).map((_, index) => (
        <div key={index} className="flex items-center gap-3 rounded-2xl border p-4" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
          <Loader2 className="h-4 w-4 animate-spin" style={{ color: 'var(--color-text-muted)' }} />
          <div className="h-3 flex-1 rounded-full" style={{ backgroundColor: 'var(--color-surface-overlay)' }} />
        </div>
      ))}
    </div>
  );
}

function formatDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(date);
}
