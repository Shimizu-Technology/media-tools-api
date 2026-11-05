import { useState, useEffect, useCallback } from 'react';
import { BackToSettings } from '../components/settings/BackToSettings';
import { Button } from '../components/ui/Button';
import {
  Plus, Trash2, ToggleLeft, ToggleRight,
  CheckCircle, XCircle, Clock, Send, AlertCircle,
} from 'lucide-react';
import {
  listWebhooks, createWebhook, updateWebhook, deleteWebhook,
  listWebhookDeliveries,
} from '../lib/api';
import type { Webhook, WebhookDelivery } from '../lib/api';

const ALL_EVENTS = [
  'transcript.completed', 'transcript.failed',
  'audio.completed', 'audio.failed',
  'pdf.completed', 'pdf.failed',
  'batch.completed',
];

/**
 * Webhook management page (MTA-18).
 * Register webhooks, toggle active state, view delivery attempts.
 */
export function WebhooksPage() {
  const [webhooks, setWebhooks] = useState<Webhook[]>([]);
  const [deliveries, setDeliveries] = useState<WebhookDelivery[]>([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [newUrl, setNewUrl] = useState('');
  const [selectedEvents, setSelectedEvents] = useState<string[]>([]);
  const [createdSecret, setCreatedSecret] = useState('');
  const [error, setError] = useState('');

  const loadData = useCallback(async () => {
    setError('');
    try {
      const [wh, del] = await Promise.all([listWebhooks(), listWebhookDeliveries()]);
      setWebhooks(wh);
      setDeliveries(del);
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to load webhooks');
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    queueMicrotask(() => {
      void loadData();
    });
  }, [loadData]);

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    if (selectedEvents.length === 0) {
      setError('Select at least one event');
      return;
    }
    try {
      const wh = await createWebhook(newUrl, selectedEvents);
      if (wh.secret) setCreatedSecret(wh.secret);
      setNewUrl('');
      setSelectedEvents([]);
      setShowForm(false);
      await loadData();
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to create webhook');
    }
  };

  const handleToggle = async (id: string, currentActive: boolean) => {
    setError('');
    try {
      await updateWebhook(id, !currentActive);
      await loadData();
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to update webhook');
    }
  };

  const handleDelete = async (id: string) => {
    setError('');
    try {
      await deleteWebhook(id);
      await loadData();
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to delete webhook');
    }
  };

  const toggleEvent = (event: string) => {
    setSelectedEvents((prev) =>
      prev.includes(event) ? prev.filter((e) => e !== event) : [...prev, event]
    );
  };

  const formatDate = (dateStr: string) => {
    return new Date(dateStr).toLocaleString('en-US', {
      month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
    });
  };

  return (
    <main className="relative pb-16">
      <div className="mx-auto max-w-2xl">
        <BackToSettings />
        <div className="mb-6 mt-1 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h1 className="text-large-title">Webhooks</h1>
            <p className="mt-2 text-callout text-text-secondary">Media Tools sends an HTTP request to your URL when a job finishes or fails.</p>
          </div>
          <Button variant="primary" onClick={() => setShowForm(!showForm)} icon={<Plus className="h-4 w-4" />}>Add a webhook</Button>
        </div>

        {/* Error display */}
        {error && !showForm && (
          <div
            className="mb-6 p-3 rounded-md border flex items-center gap-2"
            style={{
              backgroundColor: 'var(--color-fill)',
              borderColor: 'var(--color-separator)',
            }}
          >
            <AlertCircle className="w-4 h-4 shrink-0" style={{ color: 'var(--color-danger)' }} />
            <span className="text-sm" style={{ color: 'var(--color-danger)' }}>{error}</span>
          </div>
        )}

        {/* Secret display */}
        {createdSecret && (
          <div
            className="mb-6 p-4 rounded-md border"
            style={{
              backgroundColor: 'var(--color-fill)',
              borderColor: 'var(--color-separator)',
            }}
          >
            <p className="text-sm font-medium mb-1" style={{ color: 'var(--color-text)' }}>
              Webhook Secret (save this — shown only once):
            </p>
            <code className="text-xs break-all" style={{ color: 'var(--color-accent-text)' }}>
              {createdSecret}
            </code>
            <button
              onClick={() => setCreatedSecret('')}
              className="mt-2 inline-flex min-h-11 items-center rounded-sm text-xs underline"
              style={{ color: 'var(--color-text-secondary)' }}
            >
              Dismiss
            </button>
          </div>
        )}

        {/* Create form */}
        {showForm && (
          <form
            onSubmit={handleCreate}
            className="mb-6 p-6 rounded-md border space-y-4"
            style={{
              backgroundColor: 'var(--color-surface)',
              borderColor: 'var(--color-separator)',
            }}
          >
            <div>
              <label className="block text-sm font-medium mb-1.5" style={{ color: 'var(--color-text-secondary)' }}>
                Webhook URL
              </label>
              <input
                type="url"
                value={newUrl}
                onChange={(e) => setNewUrl(e.target.value)}
                placeholder="https://example.com/webhook"
                required
                className="min-h-11 w-full rounded-md border px-4 text-base outline-none sm:text-sm"
                style={{
                  backgroundColor: 'var(--color-background)',
                  borderColor: 'var(--color-separator)',
                  color: 'var(--color-text)',
                }}
              />
            </div>

            <div>
              <label className="block text-sm font-medium mb-2" style={{ color: 'var(--color-text-secondary)' }}>
                Events
              </label>
              <div className="flex flex-wrap gap-2">
                {ALL_EVENTS.map((event) => (
                  <button
                    key={event}
                    type="button"
                    onClick={() => toggleEvent(event)}
                    className="min-h-11 rounded-md border px-3 text-xs font-medium transition-colors"
                    style={{
                      backgroundColor: selectedEvents.includes(event) ? 'var(--color-accent-text)' : 'var(--color-background)',
                      color: selectedEvents.includes(event) ? 'white' : 'var(--color-text-secondary)',
                      borderColor: selectedEvents.includes(event) ? 'var(--color-accent-text)' : 'var(--color-separator)',
                    }}
                  >
                    {event}
                  </button>
                ))}
              </div>
            </div>

            {error && (
              <p className="text-sm text-danger">{error}</p>
            )}

            <div className="grid grid-cols-2 gap-3">
              <button
                type="submit"
                className="min-h-11 rounded-md px-4 text-sm font-medium text-on-accent"
                style={{ backgroundColor: 'var(--color-accent-fill)' }}
              >
                Create Webhook
              </button>
              <button
                type="button"
                onClick={() => setShowForm(false)}
                className="min-h-11 rounded-md border px-4 text-sm font-medium"
                style={{ borderColor: 'var(--color-separator)', color: 'var(--color-text-secondary)' }}
              >
                Cancel
              </button>
            </div>
          </form>
        )}

        {/* Webhooks list */}
        <div className="space-y-3 mb-10">
          {loading ? (
            <div className="text-center py-8" style={{ color: 'var(--color-text-secondary)' }}>Loading...</div>
          ) : webhooks.length === 0 ? (
            <div className="text-center py-12" style={{ color: 'var(--color-text-secondary)' }}>
              <Send className="w-8 h-8 mx-auto mb-3 opacity-50" />
              <p className="text-sm">No webhooks registered yet.</p>
            </div>
          ) : webhooks.map((wh) => (
            <div
              key={wh.id}
              className="flex flex-col items-stretch justify-between gap-4 rounded-lg border p-4 sm:flex-row sm:items-center"
              style={{
                backgroundColor: 'var(--color-surface)',
                borderColor: 'var(--color-separator)',
                opacity: wh.active ? 1 : 0.6,
              }}
            >
              <div className="min-w-0 flex-1">
                <p className="font-mono text-sm truncate" style={{ color: 'var(--color-text)' }}>{wh.url}</p>
                <div className="flex flex-wrap gap-1 mt-2">
                  {wh.events.map((e) => (
                    <span key={e} className="px-2 py-0.5 rounded-sm text-xs" style={{ backgroundColor: 'var(--color-background)', color: 'var(--color-text-secondary)' }}>
                      {e}
                    </span>
                  ))}
                </div>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                <button
                  onClick={() => handleToggle(wh.id, wh.active)}
                  className="flex min-h-11 min-w-11 items-center justify-center rounded-sm transition-colors"
                  style={{ color: wh.active ? 'var(--color-accent-text)' : 'var(--color-text-secondary)' }}
                  title={wh.active ? 'Deactivate' : 'Activate'}
                >
                  {wh.active ? <ToggleRight className="w-5 h-5" /> : <ToggleLeft className="w-5 h-5" />}
                </button>
                <button
                  onClick={() => handleDelete(wh.id)}
                  className="flex min-h-11 min-w-11 items-center justify-center rounded-sm text-danger transition-colors hover:opacity-80"
                  title="Delete webhook"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            </div>
          ))}
        </div>

        {/* Recent Deliveries */}
        {deliveries.length > 0 && (
          <div>
            <h2 className="text-lg font-semibold mb-4" style={{ color: 'var(--color-text)' }}>
              Recent Deliveries
            </h2>
            <div className="space-y-2">
              {deliveries.slice(0, 20).map((d) => (
                <div
                  key={d.id}
                  className="rounded-sm border p-3 flex items-center gap-3 text-sm"
                  style={{
                    backgroundColor: 'var(--color-surface)',
                    borderColor: 'var(--color-separator)',
                  }}
                >
                  {d.status === 'success' && <CheckCircle className="w-4 h-4 text-accent-text shrink-0" />}
                  {d.status === 'failed' && <XCircle className="w-4 h-4 text-danger shrink-0" />}
                  {d.status === 'pending' && <Clock className="w-4 h-4 shrink-0" style={{ color: 'var(--color-text-secondary)' }} />}
                  <span className="font-mono text-xs flex-1 truncate" style={{ color: 'var(--color-text)' }}>
                    {d.event}
                  </span>
                  <span className="text-xs" style={{ color: 'var(--color-text-secondary)' }}>
                    {d.response_code > 0 && `HTTP ${d.response_code} · `}
                    {formatDate(d.created_at)}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </main>
  );
}
