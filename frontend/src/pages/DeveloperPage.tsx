import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { AlertTriangle, Check, ChevronRight, Copy, Loader2, Plus, RefreshCw, Trash2 } from 'lucide-react';
import { BackToSettings } from '../components/settings/BackToSettings';
import { SettingsCard } from '../components/settings/SettingsCard';
import { Button, IconButton } from '../components/ui/Button';
import { Input, Notice, Segmented } from '../components/ui/Field';
import { LocalApiKeySetup } from '../components/LocalApiKeySetup';
import { localApiKeyMode } from '../lib/webSession';
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
  const [keyType, setKeyType] = useState<'standard' | 'agent'>('agent');
  const [scopes, setScopes] = useState<KeyScope[]>(DEFAULT_AGENT_SCOPES);
  const [activity, setActivity] = useState<AgentActivity[]>([]);
  const [isActivityLoading, setIsActivityLoading] = useState(false);
  const [activityError, setActivityError] = useState('');
  const [error, setError] = useState('');
  const [localKeyConfigured, setLocalKeyConfigured] = useState(() => localApiKeyMode && !!localStorage.getItem('mta_api_key'));
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
    <div className="mx-auto max-w-2xl pb-12">
      <BackToSettings />
      <h1 className="mt-1 text-large-title">Agent keys</h1>
      <p className="mt-2 text-callout text-text-secondary">
        Give a script, a CLI, or an agent its own key. An agent key can do only what you check, and you can revoke it at any time. <Link to="/docs" className="font-semibold text-accent">API reference</Link>
      </p>

      {!accountAuthEnabled && !localKeyConfigured && (
        <div className="mt-6">
          <LocalApiKeySetup onKeySet={() => setLocalKeyConfigured(true)} hasKey={false} />
        </div>
      )}

      {accountAuthEnabled && (
        <SettingsCard title="Create a key" description="The key is shown once. Keep it in your integration's secret store, never in browser code." id="create">
          <Segmented label="Key type" value={keyType} onChange={setKeyType} options={[{ value: 'agent', label: 'Agent key' }, { value: 'standard', label: 'Standard key' }]} />
          {keyType === 'agent' && (
            <fieldset className="mt-4">
              <legend className="text-callout font-semibold">What may this agent do with your library?</legend>
              <p className="mt-1 text-callout text-text-secondary">It acts as your account for the checked actions and nothing else. It can never manage keys, passwords, sessions, or webhooks.</p>
              <div className="mt-3 flex flex-wrap gap-2">
                {SCOPE_PRESETS.map((preset) => <Button key={preset.id} onClick={() => setScopes(preset.scopes)}>{preset.label}</Button>)}
              </div>
              <div className="mt-2 divide-y divide-separator">
                {SCOPE_OPTIONS.map((option) => (
                  <label key={option.id} className="flex min-h-12 cursor-pointer items-start gap-3 py-2.5">
                    <input type="checkbox" className="mt-1 h-4 w-4" checked={scopes.includes(option.id)} onChange={() => setScopes((current) => toggleScope(current, option.id))} />
                    <span>
                      <span className={`block text-callout font-semibold ${option.id === 'library:delete' ? 'text-danger' : ''}`}>{option.label}</span>
                      <span className="block text-meta text-text-secondary">{option.description}</span>
                    </span>
                  </label>
                ))}
              </div>
            </fieldset>
          )}
          <form className="mt-4 flex flex-col gap-2 sm:flex-row" onSubmit={(event) => { event.preventDefault(); void handleCreate(); }}>
            <Input value={name} onChange={(event) => setName(event.target.value)} placeholder={keyType === 'agent' ? 'Agent name, for example Brain Dump agent' : 'Key name'} aria-label="Key name" />
            <Button type="submit" variant="primary" busy={isCreating} disabled={!name.trim() || (keyType === 'agent' && scopes.length === 0)} icon={<Plus className="h-4 w-4" />}>Create key</Button>
          </form>
          {createdKey && (
            <div className="mt-4 rounded-md bg-fill p-3">
              <p role="status" className="flex items-center gap-2 text-callout font-semibold"><Check className="h-4 w-4 text-accent" />Copy this key now. It will not be shown again.</p>
              <div className="mt-2 flex items-center gap-2 rounded-sm bg-surface p-2 pl-3 font-mono text-meta">
                <span className="min-w-0 flex-1 break-all select-all">{createdKey}</span>
                <IconButton label="Copy API key" onClick={handleCopy}>{copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}</IconButton>
              </div>
            </div>
          )}
        </SettingsCard>
      )}

      {error && <div className="mt-4"><Notice tone="error">{error}</Notice></div>}

      <SettingsCard title="Your keys" description="Keys made here belong to your account." action={<Button variant="plain" onClick={loadKeys} icon={<RefreshCw className="h-4 w-4" />}>Refresh</Button>}>
        {isLoading ? (
          <p className="flex min-h-11 items-center gap-2 text-callout text-text-secondary" role="status"><Loader2 className="h-4 w-4 animate-spin" />Loading keys…</p>
        ) : apiKeys.length > 0 ? (
          <ul className="divide-y divide-separator">
            {apiKeys.map((key) => (
              <li key={key.id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0">
                  <p className="text-body font-semibold">{key.name}{!key.active && <span className="text-callout font-normal text-text-secondary"> · Revoked</span>}{isScopedKey(key) && <span className="text-callout font-normal text-text-secondary"> · Agent</span>}</p>
                  <p className="mt-0.5 break-words text-meta text-text-secondary tabular">{key.key_prefix} · {key.rate_limit} requests an hour · made {formatDate(key.created_at)}{key.last_used_at ? ` · last used ${formatDate(key.last_used_at)}` : ''}</p>
                  {isScopedKey(key) && key.scopes?.length ? <p className="mt-0.5 text-meta text-text-secondary">May {key.scopes.map(scopeLabel).join(', ').toLowerCase()}</p> : null}
                </div>
                {key.active && <Button variant="danger-plain" onClick={() => handleRevoke(key.id)} aria-label={`Revoke ${key.name}`} icon={<Trash2 className="h-4 w-4" />}>Revoke</Button>}
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-callout text-text-secondary">No keys yet. Make one when an agent, a CLI or another service needs to read or add to your library.</p>
        )}
      </SettingsCard>

      {accountAuthEnabled && (
        <SettingsCard title="Agent activity" description="What agent keys changed, and what they were stopped from doing. Titles and transcript text are never logged." action={<Button variant="plain" onClick={() => void loadActivity()} icon={<RefreshCw className={`h-4 w-4 ${isActivityLoading ? 'animate-spin' : ''}`} />}>Refresh</Button>}>
          {activityError ? (
            <Notice tone="error">{activityError}</Notice>
          ) : activity.length > 0 ? (
            <ul className="divide-y divide-separator">
              {activity.map((row) => (
                <li key={row.id} className="flex flex-col gap-0.5 py-3 sm:flex-row sm:items-center sm:justify-between">
                  <div className="min-w-0">
                    <p className="text-callout font-semibold">{row.status_code >= 400 && <AlertTriangle className="mr-1.5 inline h-4 w-4 text-text-secondary" aria-label="Blocked" />}{describeActivity(row)}</p>
                    <p className="mt-0.5 break-words text-meta text-text-secondary">{row.api_key_name}{activityItemLabel(row) ? ` · ${activityItemLabel(row)}` : ''}{` · ${row.status_code}`}</p>
                  </div>
                  <time className="shrink-0 text-meta text-text-secondary tabular" dateTime={row.created_at}>{formatDateTime(row.created_at)}</time>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-callout text-text-secondary">{isActivityLoading ? 'Loading activity…' : 'Nothing yet. When an agent renames, files or deletes something, it shows up here.'}</p>
          )}
        </SettingsCard>
      )}

      <SettingsCard title="Webhooks" description="Tell another service when a transcript, recording, PDF or summary is ready." action={<Link to="/app/settings/webhooks" className="inline-flex min-h-11 items-center gap-1 font-semibold text-accent">Set up webhooks <ChevronRight className="h-4 w-4" /></Link>} />
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
