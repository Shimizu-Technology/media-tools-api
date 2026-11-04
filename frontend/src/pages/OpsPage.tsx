import { useEffect, useState } from 'react';
import { BackToSettings } from '../components/settings/BackToSettings';
import { AlertCircle, Flag, RefreshCw } from 'lucide-react';
import {
  getAIContentReports,
  getAudioOpsHealth,
  updateAIContentReport,
  type AIContentReport,
  type AudioOpsHealth,
  type APIError,
} from '../lib/api';

/** Shows owner-only processing health and the AI-output moderation queue. */
export function OpsPage() {
  const [data, setData] = useState<AudioOpsHealth | null>(null);
  const [reports, setReports] = useState<AIContentReport[]>([]);
  const [loading, setLoading] = useState(false);
  const [updatingReportId, setUpdatingReportId] = useState('');
  const [error, setError] = useState('');

  const load = async () => {
    setLoading(true);
    setError('');
    try {
      const [health, reportResponse] = await Promise.all([
        getAudioOpsHealth(),
        getAIContentReports(),
      ]);
      setData(health);
      setReports(reportResponse.data);
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Failed to load ops health.');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    const timer = setInterval(load, 15000);
    return () => clearInterval(timer);
  }, []);

  const updateReport = async (
    id: string,
    status: 'reviewing' | 'resolved' | 'dismissed',
  ) => {
    setUpdatingReportId(id);
    setError('');
    try {
      const updated = await updateAIContentReport(id, status);
      setReports((current) => current.map((report) => report.id === id ? updated : report));
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Failed to update the AI output report.');
    } finally {
      setUpdatingReportId('');
    }
  };

  return (
    <main className="pb-12 sm:pb-16">
      <div className="mx-auto max-w-2xl">
        <div className="flex items-center justify-between mb-6">
          <div>
            <BackToSettings />
            <h1 className="mt-1 text-large-title">System health</h1>
          </div>
          <button
            onClick={load}
            disabled={loading}
            className="inline-flex items-center gap-2 px-3 py-2 rounded-sm text-sm font-medium border"
            style={{ borderColor: 'var(--color-separator)', color: 'var(--color-text-secondary)', minHeight: '44px' }}
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
        </div>

        {error && (
          <div className="mb-4 p-3 rounded-md border text-sm flex items-center gap-2"
            style={{ borderColor: 'var(--color-separator)', color: 'var(--color-danger)', backgroundColor: 'var(--color-fill)' }}>
            <AlertCircle className="w-4 h-4" />
            {error}
          </div>
        )}

        {data && (
          <section>
            <h2 className="mb-3 text-lg font-semibold">Audio processing</h2>
            <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-3">
              {[
                { label: 'Queue Size', value: data.queue_size },
                { label: 'Workers', value: data.worker_count },
                { label: 'Pending', value: data.pending },
                { label: 'Processing', value: data.processing },
                { label: 'Failed', value: data.failed },
                { label: 'Completed', value: data.completed },
                { label: 'Created (24h)', value: data.created_last24h },
              ].map((card) => (
                <div
                  key={card.label}
                  className="p-4 rounded-md border"
                  style={{ borderColor: 'var(--color-separator)', backgroundColor: 'var(--color-surface)' }}
                >
                  <p className="text-xs mb-1" style={{ color: 'var(--color-text-secondary)' }}>{card.label}</p>
                  <p className="text-2xl font-semibold" style={{ color: 'var(--color-text)' }}>{card.value}</p>
                </div>
              ))}
            </div>
          </section>
        )}

        <section className="mt-10">
          <div className="mb-3 flex items-center gap-2">
            <Flag className="h-4 w-4" style={{ color: 'var(--color-accent-text)' }} />
            <h2 className="text-lg font-semibold">AI output reports</h2>
            <span className="rounded-full px-2 py-0.5 text-xs font-semibold" style={{ backgroundColor: 'var(--color-fill)', color: 'var(--color-text-secondary)' }}>
              {reports.filter((report) => report.status === 'open' || report.status === 'reviewing').length} active
            </span>
          </div>
          <p className="mb-4 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
            Review the selected AI output and category. A separate source recording, transcript, or document is not attached to the report.
          </p>
          <div className="space-y-3">
            {reports.length === 0 && !loading && (
              <div className="rounded-md border p-5 text-sm" style={{ borderColor: 'var(--color-separator)', color: 'var(--color-text-secondary)' }}>
                No AI output reports have been submitted.
              </div>
            )}
            {reports.map((report) => (
              <article key={report.id} className="rounded-md border p-4" style={{ borderColor: 'var(--color-separator)', backgroundColor: 'var(--color-surface)' }}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex flex-wrap items-center gap-2 text-xs">
                    <span className="rounded-full px-2 py-1 font-semibold capitalize" style={{ backgroundColor: 'var(--color-accent-tint)', color: 'var(--color-accent-text)' }}>{report.category.replaceAll('_', ' ')}</span>
                    <span className="capitalize" style={{ color: 'var(--color-text-secondary)' }}>{report.target_type.replaceAll('_', ' ')}</span>
                    <span style={{ color: 'var(--color-text-secondary)' }}>{new Date(report.created_at).toLocaleString()}</span>
                  </div>
                  <span className="text-meta font-semibold capitalize" style={{ color: report.status === 'open' ? 'var(--color-text)' : report.status === 'resolved' ? 'var(--color-accent-text)' : 'var(--color-text-secondary)' }}>
                    {report.status}
                  </span>
                </div>
                {report.details && <p className="mt-3 text-sm" style={{ color: 'var(--color-text-secondary)' }}>{report.details}</p>}
                <pre className="mt-3 max-h-56 overflow-auto whitespace-pre-wrap rounded-md p-3 text-xs leading-5" style={{ backgroundColor: 'var(--color-fill)', color: 'var(--color-text-secondary)' }}>
                  {JSON.stringify(report.content_snapshot, null, 2)}
                </pre>
                <div className="mt-3 flex flex-wrap gap-2">
                  {report.status === 'open' && <button type="button" onClick={() => void updateReport(report.id, 'reviewing')} disabled={updatingReportId === report.id} className="min-h-11 rounded-sm border px-3 text-xs font-semibold disabled:opacity-50" style={{ borderColor: 'var(--color-separator)' }}>Start review</button>}
                  {(report.status === 'open' || report.status === 'reviewing') && <button type="button" onClick={() => void updateReport(report.id, 'resolved')} disabled={updatingReportId === report.id} className="min-h-11 rounded-sm px-3 text-xs font-semibold disabled:opacity-50" style={{ backgroundColor: 'var(--color-accent-fill)', color: 'var(--color-on-accent)' }}>Resolve</button>}
                  {(report.status === 'open' || report.status === 'reviewing') && <button type="button" onClick={() => void updateReport(report.id, 'dismissed')} disabled={updatingReportId === report.id} className="min-h-11 rounded-sm border px-3 text-xs font-semibold disabled:opacity-50" style={{ borderColor: 'var(--color-separator)' }}>Dismiss</button>}
                </div>
              </article>
            ))}
          </div>
        </section>
      </div>
    </main>
  );
}
