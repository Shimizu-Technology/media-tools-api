import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { AlertTriangle, ArrowRight, Check, Copy, ExternalLink, KeyRound, Loader2, Plus, RefreshCw, ShieldCheck, Trash2, Webhook } from 'lucide-react';
import { ApiKeySetup } from '../components/ApiKeySetup';
import { createUserAPIKey, getErrorMessage, listAPIKeys, revokeAPIKey, type APIKey } from '../lib/api';
import { useAuthContext } from '../contexts/useAuthContext';

export function DeveloperPage() {
  const { isClerkEnabled } = useAuthContext();
  const [apiKeys, setApiKeys] = useState<APIKey[]>([]);
  const [name, setName] = useState('media-tools-app');
  const [createdKey, setCreatedKey] = useState('');
  const [copied, setCopied] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState('');
  const [localKeyConfigured, setLocalKeyConfigured] = useState(() => !!localStorage.getItem('mta_api_key'));

  const loadKeys = async () => {
    setIsLoading(true);
    setError('');
    try {
      setApiKeys(await listAPIKeys());
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setIsLoading(false);
    }
  };

  useEffect(() => {
    if (isClerkEnabled || localKeyConfigured) {
      void loadKeys();
    } else {
      setIsLoading(false);
    }
  }, [isClerkEnabled, localKeyConfigured]);

  const handleCreate = async () => {
    if (!name.trim()) return;
    setIsCreating(true);
    setError('');
    setCreatedKey('');
    try {
      const key = await createUserAPIKey(name.trim());
      if (key.raw_key) setCreatedKey(key.raw_key);
      setName('media-tools-app');
      await loadKeys();
    } catch (err) {
      setError(getErrorMessage(err));
    } finally {
      setIsCreating(false);
    }
  };

  const handleCopy = async () => {
    if (!createdKey) return;
    await navigator.clipboard.writeText(createdKey);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleRevoke = async (id: string) => {
    if (!window.confirm('Revoke this API key? Apps using it will stop working.')) return;
    setError('');
    try {
      await revokeAPIKey(id);
      await loadKeys();
    } catch (err) {
      setError(getErrorMessage(err));
    }
  };

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <section className="rounded-[2rem] border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.2em]" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
          <ShieldCheck className="h-3.5 w-3.5" />
          Developer settings
        </div>
        <div className="mt-5 grid gap-5 lg:grid-cols-[1fr_0.6fr] lg:items-end">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl" style={{ color: 'var(--color-text-primary)' }}>API keys live here now.</h1>
            <p className="mt-3 max-w-2xl text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
              Normal users can stay in the workspace. Developers can create API keys, configure webhooks, and read integration docs from this section.
            </p>
          </div>
          <div className="flex flex-wrap justify-start gap-3 lg:justify-end">
            <Link to="/docs" className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-4 text-sm font-semibold transition hover:bg-white/[0.06]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
              API docs
              <ExternalLink className="h-4 w-4" />
            </Link>
            <Link to="/app/developer/webhooks" className="inline-flex min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition hover:opacity-90" style={{ backgroundColor: 'var(--color-brand-500)' }}>
              Webhooks
              <Webhook className="h-4 w-4" />
            </Link>
          </div>
        </div>
      </section>

      {!isClerkEnabled && !localKeyConfigured && (
        <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <ApiKeySetup onKeySet={() => setLocalKeyConfigured(true)} hasKey={false} />
        </section>
      )}

      {isClerkEnabled && (
        <section className="rounded-[2rem] border p-6 sm:p-8" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <div className="flex items-start gap-4">
            <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
              <KeyRound className="h-5 w-5" />
            </div>
            <div className="flex-1">
              <h2 className="text-xl font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>Create a developer API key</h2>
              <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
                The raw key is shown once. Store it in your integration's secret manager, not in browser code.
              </p>
              <div className="mt-5 flex flex-col gap-3 sm:flex-row">
                <input
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  className="min-h-11 flex-1 rounded-xl border px-4 text-sm outline-none transition focus:border-[var(--color-brand-500)]"
                  style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}
                  placeholder="Key name"
                />
                <button
                  type="button"
                  onClick={handleCreate}
                  disabled={isCreating || !name.trim()}
                  className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition disabled:cursor-not-allowed disabled:opacity-60"
                  style={{ backgroundColor: 'var(--color-brand-500)' }}
                >
                  {isCreating ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
                  Create key
                </button>
              </div>

              {createdKey && (
                <div className="mt-5 rounded-2xl border p-4" style={{ backgroundColor: 'var(--color-surface-subtle)', borderColor: 'var(--color-border)' }}>
                  <div className="mb-2 flex items-center gap-2 text-sm font-semibold" style={{ color: 'var(--color-success)' }}>
                    <Check className="h-4 w-4" />
                    Copy this key now. It will not be shown again.
                  </div>
                  <div className="flex items-center gap-3 rounded-xl border p-3 font-mono text-xs" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
                    <span className="min-w-0 flex-1 break-all">{createdKey}</span>
                    <button type="button" onClick={handleCopy} className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border" style={{ borderColor: 'var(--color-border)' }} aria-label="Copy API key">
                      {copied ? <Check className="h-4 w-4" style={{ color: 'var(--color-success)' }} /> : <Copy className="h-4 w-4" />}
                    </button>
                  </div>
                </div>
              )}
            </div>
          </div>
        </section>
      )}

      {error && (
        <div className="flex items-center gap-2 rounded-2xl border px-4 py-3 text-sm" style={{ backgroundColor: 'rgba(239,68,68,0.08)', borderColor: 'var(--color-danger)', color: 'var(--color-danger)' }}>
          <AlertTriangle className="h-4 w-4" />
          {error}
        </div>
      )}

      <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-xl font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>Your API keys</h2>
            <p className="mt-1 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Keys are scoped to your account when created from this page.</p>
          </div>
          <button type="button" onClick={loadKeys} className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-4 text-sm font-semibold transition hover:bg-white/[0.06]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
            <RefreshCw className="h-4 w-4" />
            Refresh
          </button>
        </div>

        {isLoading ? (
          <div className="flex items-center gap-3 rounded-2xl border p-4" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}>
            <Loader2 className="h-4 w-4 animate-spin" />
            Loading API keys...
          </div>
        ) : apiKeys.length > 0 ? (
          <div className="overflow-hidden rounded-2xl border" style={{ borderColor: 'var(--color-border)' }}>
            <div className="divide-y" style={{ borderColor: 'var(--color-border)' }}>
              {apiKeys.map((key) => (
                <div key={key.id} className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between" style={{ backgroundColor: 'var(--color-surface-subtle)' }}>
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>{key.name}</p>
                      <span className="rounded-full px-2 py-0.5 text-xs font-semibold" style={{ backgroundColor: 'var(--color-surface-overlay)', color: key.active ? 'var(--color-success)' : 'var(--color-text-muted)' }}>
                        {key.active ? 'Active' : 'Revoked'}
                      </span>
                    </div>
                    <p className="mt-1 font-mono text-xs" style={{ color: 'var(--color-text-muted)' }}>{key.key_prefix} · {key.rate_limit} req/hr · created {formatDate(key.created_at)}</p>
                  </div>
                  <button type="button" onClick={() => handleRevoke(key.id)} disabled={!key.active} className="inline-flex min-h-10 items-center justify-center gap-2 rounded-xl border px-3 text-sm font-semibold transition disabled:cursor-not-allowed disabled:opacity-50" style={{ borderColor: 'var(--color-border)', color: 'var(--color-danger)' }}>
                    <Trash2 className="h-4 w-4" />
                    Revoke
                  </button>
                </div>
              ))}
            </div>
          </div>
        ) : (
          <div className="rounded-2xl border border-dashed p-8 text-center" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
            <KeyRound className="mx-auto mb-3 h-8 w-8" style={{ color: 'var(--color-brand-500)' }} />
            <p className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>No API keys yet</p>
            <p className="mt-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Create one when you need CLI access, webhooks, or server-to-server integrations.</p>
          </div>
        )}
      </section>

      <section className="grid gap-4 md:grid-cols-2">
        <Link to="/docs" className="group rounded-3xl border p-5 transition hover:-translate-y-0.5" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <p className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>Public API documentation</p>
          <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>Review endpoints, request shapes, and curl examples.</p>
          <span className="mt-4 inline-flex items-center gap-1 text-sm font-semibold" style={{ color: 'var(--color-brand-500)' }}>Open docs <ArrowRight className="h-4 w-4" /></span>
        </Link>
        <Link to="/app/developer/webhooks" className="group rounded-3xl border p-5 transition hover:-translate-y-0.5" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <p className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>Webhook delivery settings</p>
          <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>Subscribe your integration to transcript, audio, PDF, and summary events.</p>
          <span className="mt-4 inline-flex items-center gap-1 text-sm font-semibold" style={{ color: 'var(--color-brand-500)' }}>Configure webhooks <ArrowRight className="h-4 w-4" /></span>
        </Link>
      </section>
    </div>
  );
}

function formatDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', year: 'numeric' }).format(date);
}
