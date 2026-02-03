import { useState, useEffect } from 'react';
import { motion } from 'framer-motion';
import {
  Webhook as WebhookIcon, Plus, Trash2, ToggleLeft, ToggleRight,
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

  useEffect(() => { loadData(); }, []);

  const loadData = async () => {
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
  };

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
    <main className="relative pt-28 pb-16 px-6">
      <div className="max-w-4xl mx-auto">
        {/* Header */}
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
          className="flex items-center justify-between mb-8"
        >
          <div>
            <div className="flex items-center gap-3 mb-2">
              <WebhookIcon className="w-6 h-6" style={{ color: 'var(--color-brand-500)' }} />
              <h1 className="text-2xl font-bold" style={{ color: 'var(--color-text-primary)' }}>
                Webhooks
              </h1>
            </div>
            <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
              Receive HTTP notifications when jobs complete or fail.
            </p>
          </div>
          <button
            onClick={() => setShowForm(!showForm)}
            className="flex items-center gap-2 px-4 py-2.5 rounded-xl text-white text-sm font-medium transition-all"
            style={{ backgroundColor: 'var(--color-brand-500)' }}
          >
            <Plus className="w-4 h-4" />
            <span className="hidden sm:inline">Add Webhook</span>
          </button>
        </motion.div>

        {/* Error display */}
        {error && !showForm && (
          <motion.div
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            className="mb-6 p-3 rounded-xl border flex items-center gap-2"
            style={{
              backgroundColor: 'rgba(239, 68, 68, 0.1)',
              borderColor: 'rgba(239, 68, 68, 0.3)',
            }}
          >
            <AlertCircle className="w-4 h-4 text-red-500 shrink-0" />
            <span className="text-sm text-red-500">{error}</span>
          </motion.div>
        )}

        {/* Secret display */}
        {createdSecret && (
          <motion.div
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            className="mb-6 p-4 rounded-xl border"
            style={{
              backgroundColor: 'rgba(34, 197, 94, 0.05)',
              borderColor: 'rgba(34, 197, 94, 0.2)',
            }}
          >
            <p className="text-sm font-medium mb-1" style={{ color: 'var(--color-text-primary)' }}>
              Webhook Secret (save this — shown only once):
            </p>
            <code className="text-xs break-all" style={{ color: 'var(--color-brand-500)' }}>
              {createdSecret}
            </code>
            <button
              onClick={() => setCreatedSecret('')}
              className="block mt-2 text-xs underline"
              style={{ color: 'var(--color-text-muted)' }}
            >
              Dismiss
            </button>
          </motion.div>
        )}

        {/* Create form */}
        {showForm && (
          <motion.form
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            onSubmit={handleCreate}
            className="mb-6 p-6 rounded-xl border space-y-4"
            style={{
              backgroundColor: 'var(--color-surface-elevated)',
              borderColor: 'var(--color-border)',
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
                className="w-full px-4 py-2.5 rounded-xl border text-sm outline-none"
                style={{
                  backgroundColor: 'var(--color-surface)',
                  borderColor: 'var(--color-border)',
                  color: 'var(--color-text-primary)',
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
                    className="px-3 py-1.5 rounded-lg text-xs font-medium border transition-all"
                    style={{
                      backgroundColor: selectedEvents.includes(event) ? 'var(--color-brand-500)' : 'var(--color-surface)',
                      color: selectedEvents.includes(event) ? 'white' : 'var(--color-text-secondary)',
                      borderColor: selectedEvents.includes(event) ? 'var(--color-brand-500)' : 'var(--color-border)',
                    }}
                  >
                    {event}
                  </button>
                ))}
              </div>
            </div>

            {error && (
              <p className="text-sm text-red-500">{error}</p>
            )}

            <div className="flex gap-3">
              <button
                type="submit"
                className="px-4 py-2 rounded-xl text-white text-sm font-medium"
                style={{ backgroundColor: 'var(--color-brand-500)' }}
              >
                Create Webhook
              </button>
              <button
                type="button"
                onClick={() => setShowForm(false)}
                className="px-4 py-2 rounded-xl text-sm font-medium border"
                style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}
              >
                Cancel
              </button>
            </div>
          </motion.form>
        )}

        {/* Webhooks list */}
        <div className="space-y-3 mb-10">
          {loading ? (
            <div className="text-center py-8" style={{ color: 'var(--color-text-muted)' }}>Loading...</div>
          ) : webhooks.length === 0 ? (
            <div className="text-center py-12" style={{ color: 'var(--color-text-muted)' }}>
              <Send className="w-8 h-8 mx-auto mb-3 opacity-50" />
              <p className="text-sm">No webhooks registered yet.</p>
            </div>
          ) : webhooks.map((wh) => (
            <motion.div
              key={wh.id}
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              className="rounded-xl border p-4 flex items-center justify-between gap-4"
              style={{
                backgroundColor: 'var(--color-surface-elevated)',
                borderColor: 'var(--color-border)',
                opacity: wh.active ? 1 : 0.6,
              }}
            >
              <div className="min-w-0 flex-1">
                <p className="font-mono text-sm truncate" style={{ color: 'var(--color-text-primary)' }}>{wh.url}</p>
                <div className="flex flex-wrap gap-1 mt-2">
                  {wh.events.map((e) => (
                    <span key={e} className="px-2 py-0.5 rounded text-xs" style={{ backgroundColor: 'var(--color-surface)', color: 'var(--color-text-muted)' }}>
                      {e}
                    </span>
                  ))}
                </div>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                <button
                  onClick={() => handleToggle(wh.id, wh.active)}
                  className="p-2 rounded-lg transition-colors"
                  style={{ color: wh.active ? 'var(--color-brand-500)' : 'var(--color-text-muted)' }}
                  title={wh.active ? 'Deactivate' : 'Activate'}
                >
                  {wh.active ? <ToggleRight className="w-5 h-5" /> : <ToggleLeft className="w-5 h-5" />}
                </button>
                <button
                  onClick={() => handleDelete(wh.id)}
                  className="p-2 rounded-lg transition-colors text-red-500 hover:opacity-80"
                  title="Delete webhook"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            </motion.div>
          ))}
        </div>

        {/* Recent Deliveries */}
        {deliveries.length > 0 && (
          <div>
            <h2 className="text-lg font-semibold mb-4" style={{ color: 'var(--color-text-primary)' }}>
              Recent Deliveries
            </h2>
            <div className="space-y-2">
              {deliveries.slice(0, 20).map((d) => (
                <div
                  key={d.id}
                  className="rounded-lg border p-3 flex items-center gap-3 text-sm"
                  style={{
                    backgroundColor: 'var(--color-surface-elevated)',
                    borderColor: 'var(--color-border)',
                  }}
                >
                  {d.status === 'success' && <CheckCircle className="w-4 h-4 text-green-500 shrink-0" />}
                  {d.status === 'failed' && <XCircle className="w-4 h-4 text-red-500 shrink-0" />}
                  {d.status === 'pending' && <Clock className="w-4 h-4 shrink-0" style={{ color: 'var(--color-text-muted)' }} />}
                  <span className="font-mono text-xs flex-1 truncate" style={{ color: 'var(--color-text-primary)' }}>
                    {d.event}
                  </span>
                  <span className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
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
