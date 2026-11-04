import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { Activity, AlertTriangle, ArrowRight, Bot, Check, Copy, ExternalLink, KeyRound, Loader2, Plus, RefreshCw, ShieldCheck, Trash2, Webhook } from 'lucide-react';
import { ApiKeySetup } from '../components/ApiKeySetup';
import { createUserAPIKey, getErrorMessage, listAgentActivity, listAPIKeys, revokeAPIKey, type AgentActivity, type APIKey } from '../lib/api';
import { activityItemLabel, DEFAULT_AGENT_SCOPES, describeActivity, isScopedKey, SCOPE_OPTIONS, SCOPE_PRESETS, scopeLabel, toggleScope, type KeyScope } from '../lib/agentAccess';
import { useAuthContext } from '../contexts/useAuthContext';

export function DeveloperPage() {
  const { accountAuthEnabled } = useAuthContext();
  const [apiKeys, setApiKeys] = useState<APIKey[]>([]);
  const [name, setName] = useState('media-tools-app');
  const [createdKey, setCreatedKey] = useState('');
  const [copied, setCopied] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [isCreating, setIsCreating] = useState(false);
  const [keyType, setKeyType] = useState<'standard' | 'agent'>('standard');
  const [scopes, setScopes] = useState<KeyScope[]>(DEFAULT_AGENT_SCOPES);
  const [activity, setActivity] = useState<AgentActivity[]>([]);
  const [isActivityLoading, setIsActivityLoading] = useState(false);
  const [activityError, setActivityError] = useState('');
  const [error, setError] = useState('');
  const [localKeyConfigured, setLocalKeyConfigured] = useState(() => !!localStorage.getItem('mta_api_key'));
  const isMountedRef = useRef(false);
  const copyResetTimeoutRef = useRef<number | null>(null);

  useEffect(() => {
    isMountedRef.current = true;
    return () => {
      isMountedRef.current = false;
      if (copyResetTimeoutRef.current !== null) {
        window.clearTimeout(copyResetTimeoutRef.current);
      }
    };
  }, []);

  const loadKeys = useCallback(async () => {
    setIsLoading(true);
    setError('');
    try {
      const keys = await listAPIKeys();
      if (!isMountedRef.current) return;
      setApiKeys(keys);
    } catch (err) {
      if (!isMountedRef.current) return;
      setError(getErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setIsLoading(false);
      }
    }
  }, []);

  // Agent activity belongs to the signed-in account, so a locally pasted dev
  // key cannot read it.
  const loadActivity = useCallback(async () => {
    setIsActivityLoading(true);
    setActivityError('');
    try {
      const rows = await listAgentActivity();
      if (!isMountedRef.current) return;
      setActivity(rows);
    } catch (err) {
      if (!isMountedRef.current) return;
      setActivityError(getErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setIsActivityLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    if (accountAuthEnabled || localKeyConfigured) {
      void loadKeys();
    } else {
      setIsLoading(false);
    }
  }, [accountAuthEnabled, localKeyConfigured, loadKeys]);

  useEffect(() => {
    if (accountAuthEnabled) {
      void loadActivity();
    }
  }, [accountAuthEnabled, loadActivity]);

  const handleCreate = async () => {
    const trimmedName = name.trim();
    if (!trimmedName) return;
    if (keyType === 'agent' && scopes.length === 0) {
      setError('Choose at least one thing this agent key can do.');
      return;
    }
    setIsCreating(true);
    setError('');
    setCreatedKey('');
    try {
      const key = await createUserAPIKey(trimmedName, keyType === 'agent' ? scopes : undefined);
      if (!isMountedRef.current) return;
      if (key.raw_key) setCreatedKey(key.raw_key);
      setName('media-tools-app');
      await loadKeys();
      if (accountAuthEnabled) void loadActivity();
    } catch (err) {
      if (!isMountedRef.current) return;
      setError(getErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setIsCreating(false);
      }
    }
  };

  const handleCopy = async () => {
    if (!createdKey) return;
    await navigator.clipboard.writeText(createdKey);
    if (!isMountedRef.current) return;
    setCopied(true);
    if (copyResetTimeoutRef.current !== null) {
      window.clearTimeout(copyResetTimeoutRef.current);
    }
    copyResetTimeoutRef.current = window.setTimeout(() => {
      if (isMountedRef.current) {
        setCopied(false);
      }
    }, 2000);
  };

  const handleRevoke = async (id: string) => {
    if (!window.confirm('Revoke this API key? Apps using it will stop working.')) return;
    setError('');
    try {
      await revokeAPIKey(id);
      if (!isMountedRef.current) return;
      await loadKeys();
      if (accountAuthEnabled) void loadActivity();
    } catch (err) {
      if (!isMountedRef.current) return;
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

      {!accountAuthEnabled && !localKeyConfigured && (
        <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <ApiKeySetup onKeySet={() => setLocalKeyConfigured(true)} hasKey={false} />
        </section>
      )}

      {accountAuthEnabled && (
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
              <div className="mt-5 inline-flex rounded-xl border p-1" role="radiogroup" aria-label="Key type" style={{ borderColor: 'var(--color-border)' }}>
                {([['standard', 'Standard key'], ['agent', 'Agent key']] as const).map(([value, label]) => (
                  <button
                    key={value}
                    type="button"
                    role="radio"
                    aria-checked={keyType === value}
                    onClick={() => setKeyType(value)}
                    className="inline-flex min-h-11 items-center gap-2 rounded-lg px-4 text-sm font-semibold transition"
                    style={keyType === value ? { backgroundColor: 'var(--color-brand-500)', color: '#fff' } : { color: 'var(--color-text-secondary)' }}
                  >
                    {value === 'agent' && <Bot className="h-4 w-4" />}
                    {label}
                  </button>
                ))}
              </div>
              {keyType === 'agent' && (
                <fieldset className="mt-4 rounded-2xl border p-4" style={{ backgroundColor: 'var(--color-surface-subtle)', borderColor: 'var(--color-border)' }}>
                  <legend className="px-2 text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>What can this agent do with your library?</legend>
                  <p className="mb-3 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>
                    An agent key acts as your account for the checked actions and nothing else. It can never manage keys, passwords, sessions, or webhooks.
                  </p>
                  <div className="mb-3 flex flex-wrap gap-2">
                    {SCOPE_PRESETS.map((preset) => (
                      <button key={preset.id} type="button" onClick={() => setScopes(preset.scopes)} className="min-h-11 rounded-xl border px-3 text-sm font-semibold transition hover:bg-white/[0.06]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
                        {preset.label}
                      </button>
                    ))}
                  </div>
                  <div className="space-y-1">
                    {SCOPE_OPTIONS.map((option) => (
                      <label key={option.id} className="flex min-h-11 cursor-pointer items-start gap-3 rounded-xl p-2">
                        <input type="checkbox" className="mt-1 h-4 w-4" checked={scopes.includes(option.id)} onChange={() => setScopes((current) => toggleScope(current, option.id))} />
                        <span>
                          <span className="block text-sm font-semibold" style={{ color: option.id === 'library:delete' ? 'var(--color-danger)' : 'var(--color-text-primary)' }}>{option.label}</span>
                          <span className="block text-xs leading-5" style={{ color: 'var(--color-text-secondary)' }}>{option.description}</span>
                        </span>
                      </label>
                    ))}
                  </div>
                </fieldset>
              )}
              <div className="mt-5 flex flex-col gap-3 sm:flex-row">
                <input
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  className="min-h-11 flex-1 rounded-xl border px-4 text-sm outline-none transition focus:border-[var(--color-brand-500)]"
                  style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}
                  placeholder={keyType === 'agent' ? 'Agent name, for example Brain Dump agent' : 'Key name'}
                  aria-label="Key name"
                />
                <button
                  type="button"
                  onClick={handleCreate}
                  disabled={isCreating || !name.trim() || (keyType === 'agent' && scopes.length === 0)}
                  className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 text-sm font-semibold text-white transition disabled:cursor-not-allowed disabled:opacity-60"
                  style={{ backgroundColor: 'var(--color-brand-500)' }}
                >
                  {isCreating ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
                  Create key
                </button>
              </div>

              {createdKey && (
                <div className="mt-5 rounded-2xl border p-4" style={{ backgroundColor: 'var(--color-surface-subtle)', borderColor: 'var(--color-border)' }}>
                  <div role="status" className="mb-2 flex items-center gap-2 text-sm font-semibold" style={{ color: 'var(--color-success)' }}>
                    <Check className="h-4 w-4" />
                    Copy this key now. It will not be shown again.
                  </div>
                  <div className="flex items-center gap-3 rounded-xl border p-3 font-mono text-xs" style={{ backgroundColor: 'var(--color-surface)', borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
                    <span className="min-w-0 flex-1 break-all">{createdKey}</span>
                    <button type="button" onClick={handleCopy} className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-xl border" style={{ borderColor: 'var(--color-border)' }} aria-label="Copy API key">
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
                    <p className="mt-1 break-words font-mono text-xs" style={{ color: 'var(--color-text-muted)' }}>{key.key_prefix} · {key.rate_limit} req/hr · created {formatDate(key.created_at)}{key.last_used_at ? ` · last used ${formatDate(key.last_used_at)}` : ''}</p>
                    {isScopedKey(key) && (
                      <div className="mt-2 flex flex-wrap items-center gap-1.5" aria-label={`Scopes for ${key.name}`}>
                        <span className="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-500)' }}>
                          <Bot className="h-3 w-3" />
                          Agent
                        </span>
                        {key.scopes?.map((scope) => (
                          <span key={scope} className="rounded-full border px-2 py-0.5 text-xs" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-secondary)' }}>{scopeLabel(scope)}</span>
                        ))}
                      </div>
                    )}
                  </div>
                  <button type="button" onClick={() => handleRevoke(key.id)} disabled={!key.active} aria-label={`Revoke ${key.name}`} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-3 text-sm font-semibold transition disabled:cursor-not-allowed disabled:opacity-50" style={{ borderColor: 'var(--color-border)', color: 'var(--color-danger)' }}>
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

      {accountAuthEnabled && (
        <section className="rounded-[2rem] border p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
          <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 className="flex items-center gap-2 text-xl font-semibold tracking-tight" style={{ color: 'var(--color-text-primary)' }}>
                <Activity className="h-5 w-5" style={{ color: 'var(--color-brand-500)' }} />
                Recent agent activity
              </h2>
              <p className="mt-1 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Changes made with agent keys, and requests they were blocked from. Titles and transcript text are never logged.</p>
            </div>
            <button type="button" onClick={() => void loadActivity()} className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-4 text-sm font-semibold transition hover:bg-white/[0.06]" style={{ borderColor: 'var(--color-border)', color: 'var(--color-text-primary)' }}>
              <RefreshCw className={`h-4 w-4 ${isActivityLoading ? 'animate-spin' : ''}`} />
              Refresh
            </button>
          </div>
          {activityError ? (
            <div role="alert" className="flex items-center gap-2 rounded-2xl border px-4 py-3 text-sm" style={{ borderColor: 'var(--color-danger)', color: 'var(--color-danger)' }}>
              <AlertTriangle className="h-4 w-4" />
              {activityError}
            </div>
          ) : activity.length > 0 ? (
            <ul className="divide-y overflow-hidden rounded-2xl border" style={{ borderColor: 'var(--color-border)' }}>
              {activity.map((row) => (
                <li key={row.id} className="flex flex-col gap-1 p-4 sm:flex-row sm:items-center sm:justify-between" style={{ backgroundColor: 'var(--color-surface-subtle)', borderColor: 'var(--color-border)' }}>
                  <div className="min-w-0">
                    <p className="text-sm font-semibold" style={{ color: row.status_code >= 400 ? 'var(--color-danger)' : 'var(--color-text-primary)' }}>{describeActivity(row)}</p>
                    <p className="mt-0.5 break-words text-xs" style={{ color: 'var(--color-text-muted)' }}>
                      {row.api_key_name}
                      {activityItemLabel(row) ? ` · ${activityItemLabel(row)}` : ''}
                      {` · ${row.status_code}`}
                    </p>
                  </div>
                  <time className="shrink-0 text-xs" dateTime={row.created_at} style={{ color: 'var(--color-text-muted)' }}>{formatDateTime(row.created_at)}</time>
                </li>
              ))}
            </ul>
          ) : (
            <div className="rounded-2xl border border-dashed p-8 text-center" style={{ borderColor: 'var(--color-border)', backgroundColor: 'var(--color-surface-subtle)' }}>
              <Bot className="mx-auto mb-3 h-8 w-8" style={{ color: 'var(--color-brand-500)' }} />
              <p className="font-semibold" style={{ color: 'var(--color-text-primary)' }}>{isActivityLoading ? 'Loading activity...' : 'No agent activity yet'}</p>
              <p className="mt-2 text-sm" style={{ color: 'var(--color-text-secondary)' }}>When an agent key renames, files, or deletes something, it shows up here.</p>
            </div>
          )}
        </section>
      )}

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

function formatDateTime(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(date);
}

function formatDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', year: 'numeric' }).format(date);
}
