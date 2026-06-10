import { useEffect, useState } from 'react';
import { Activity, AlertCircle, RefreshCw } from 'lucide-react';
import { getAudioOpsHealth, type AudioOpsHealth, type APIError } from '../lib/api';

export function OpsPage() {
  const [data, setData] = useState<AudioOpsHealth | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const load = async () => {
    setLoading(true);
    setError('');
    try {
      const res = await getAudioOpsHealth();
      setData(res);
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

  return (
    <main className="pb-12 sm:pb-16">
      <div className="max-w-4xl mx-auto">
        <div className="flex items-center justify-between mb-6">
          <div>
            <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full text-xs font-semibold mb-3"
              style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
              <Activity className="w-3.5 h-3.5" />
              Operations
            </div>
            <h1 className="text-3xl sm:text-4xl font-bold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>
              Audio Processing Health
            </h1>
          </div>
          <button
            onClick={load}
            disabled={loading}
            className="inline-flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium border"
            style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)', minHeight: '44px' }}
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
        </div>

        {error && (
          <div className="mb-4 p-3 rounded-xl border text-sm flex items-center gap-2"
            style={{ borderColor: 'rgba(239,68,68,0.3)', color: 'var(--color-error)', backgroundColor: 'rgba(239,68,68,0.08)' }}>
            <AlertCircle className="w-4 h-4" />
            {error}
          </div>
        )}

        {data && (
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
                className="p-4 rounded-xl border"
                style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-elevated)' }}
              >
                <p className="text-xs mb-1" style={{ color: 'var(--color-text-muted)' }}>{card.label}</p>
                <p className="text-2xl font-semibold" style={{ color: 'var(--color-text-primary)' }}>{card.value}</p>
              </div>
            ))}
          </div>
        )}
      </div>
    </main>
  );
}
