import { useState } from 'react';
import { Key, Check, AlertTriangle, Copy } from 'lucide-react';
import { createAPIKey } from '../lib/api';

interface ApiKeySetupProps {
  onKeySet: (key: string) => void;
  hasKey: boolean;
}

/**
 * API key setup component.
 * Creates a new key or accepts an existing one.
 * Lucide icons only — no emoji.
 */
export function ApiKeySetup({ onKeySet, hasKey }: ApiKeySetupProps) {
  const [mode, setMode] = useState<'create' | 'existing'>('create');
  const [name, setName] = useState('web-app');
  const [adminKey, setAdminKey] = useState('');
  const [existingKey, setExistingKey] = useState('');
  const [createdKey, setCreatedKey] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);

  const handleCreate = async () => {
    setIsLoading(true);
    setError('');
    try {
      const result = await createAPIKey(name, { adminKey: adminKey.trim() || undefined });
      if (result.raw_key) {
        setCreatedKey(result.raw_key);
        localStorage.setItem('mta_api_key', result.raw_key);
        onKeySet(result.raw_key);
      }
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to create API key. Check your admin key.');
    }
    setIsLoading(false);
  };

  const handleUseExisting = () => {
    if (existingKey.trim()) {
      localStorage.setItem('mta_api_key', existingKey.trim());
      onKeySet(existingKey.trim());
    }
  };

  const handleCopy = async () => {
    await navigator.clipboard.writeText(createdKey);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  if (hasKey) return null;

  return (
    <div
      className="w-full max-w-md mx-auto"
    >
      <div
        className="p-6 rounded-lg border"
        style={{
          backgroundColor: 'var(--color-surface)',
          borderColor: 'var(--color-separator)',
        }}
      >
        <div className="flex items-center gap-3 mb-4">
          <div
            className="w-10 h-10 rounded-md flex items-center justify-center"
            style={{ backgroundColor: 'var(--color-accent-tint)' }}
          >
            <Key className="w-5 h-5" style={{ color: 'var(--color-accent)' }} />
          </div>
          <div>
            <h3 className="text-base font-semibold" style={{ color: 'var(--color-text)' }}>
              API Key Required
            </h3>
            <p className="text-xs" style={{ color: 'var(--color-text-secondary)' }}>
              You need an API key to extract transcripts
            </p>
          </div>
        </div>

        {/* Tab selector */}
        <div className="flex gap-1 p-1 rounded-sm mb-4" style={{ backgroundColor: 'var(--color-bg)' }}>
          {(['create', 'existing'] as const).map((tab) => (
            <button
              key={tab}
              onClick={() => setMode(tab)}
              className="flex-1 py-2 px-3 rounded-sm text-sm font-medium transition-colors duration-200"
              style={{
                backgroundColor: mode === tab ? 'var(--color-surface)' : 'transparent',
                color: mode === tab ? 'var(--color-text)' : 'var(--color-text-secondary)',
              }}
            >
              {tab === 'create' ? 'Create New' : 'Use Existing'}
            </button>
          ))}
        </div>
          {mode === 'create' ? (
            <div key="create">
              {!createdKey ? (
                <>
                  <input
                    type="password"
                    value={adminKey}
                    onChange={(e) => setAdminKey(e.target.value)}
                    placeholder="Admin key (production only)"
                    className="w-full px-4 py-3 rounded-md border text-sm outline-none transition-colors duration-200"
                    style={{
                      backgroundColor: 'var(--color-bg)',
                      borderColor: 'var(--color-separator)',
                      color: 'var(--color-text)',
                      minHeight: '44px',
                    }}
                  />
                  <input
                    type="text"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    placeholder="Key name (e.g., my-app)"
                    className="w-full mt-2 px-4 py-3 rounded-md border text-sm outline-none transition-colors duration-200"
                    style={{
                      backgroundColor: 'var(--color-bg)',
                      borderColor: 'var(--color-separator)',
                      color: 'var(--color-text)',
                      minHeight: '44px',
                    }}
                  />
                  <button
                    onClick={handleCreate}
                    disabled={isLoading || !name.trim()}
                    className="w-full mt-3 py-3 rounded-md text-on-accent font-medium text-sm transition-opacity duration-200 disabled:opacity-50"
                    style={{ backgroundColor: 'var(--color-accent-fill)', minHeight: '44px' }}
                  >
                    {isLoading ? 'Creating...' : 'Create API Key'}
                  </button>
                  <p className="text-xs mt-2 text-center" style={{ color: 'var(--color-text-secondary)' }}>
                    Production requires the admin key from your Render environment variables
                  </p>
                </>
              ) : (
                <div>
                  <div className="flex items-center gap-2 mb-2">
                    <Check className="w-4 h-4 text-accent" />
                    <span className="text-sm font-medium text-accent">Key created! Save it now.</span>
                  </div>
                  <div
                    className="flex items-center gap-2 p-3 rounded-sm text-xs font-mono break-all"
                    style={{
                      backgroundColor: 'var(--color-bg)',
                      border: '1px solid var(--color-separator)',
                      color: 'var(--color-text)',
                    }}
                  >
                    <span className="flex-1">{createdKey}</span>
                    <button onClick={handleCopy} className="shrink-0 p-1.5 rounded-sm hover:opacity-80">
                      {copied ? <Check className="w-4 h-4 text-accent" /> : <Copy className="w-4 h-4" style={{ color: 'var(--color-text-secondary)' }} />}
                    </button>
                  </div>
                  <div className="flex items-center gap-1.5 mt-2">
                    <AlertTriangle className="w-3.5 h-3.5 text-text-secondary" />
                    <span className="text-xs text-text-secondary">
                      This key won't be shown again. Copy it somewhere safe.
                    </span>
                  </div>
                </div>
              )}
            </div>
          ) : (
            <div key="existing">
              <input
                type="text"
                value={existingKey}
                onChange={(e) => setExistingKey(e.target.value)}
                placeholder="mta_abc123..."
                className="w-full px-4 py-3 rounded-md border text-sm font-mono outline-none transition-colors duration-200"
                style={{
                  backgroundColor: 'var(--color-bg)',
                  borderColor: 'var(--color-separator)',
                  color: 'var(--color-text)',
                  minHeight: '44px',
                }}
              />
              <button
                onClick={handleUseExisting}
                disabled={!existingKey.trim()}
                className="w-full mt-3 py-3 rounded-md text-on-accent font-medium text-sm transition-opacity duration-200 disabled:opacity-50"
                style={{ backgroundColor: 'var(--color-accent-fill)', minHeight: '44px' }}
              >
                Use This Key
              </button>
            </div>
          )}

        {error && (
          <p className="text-sm text-danger mt-3 flex items-center gap-1.5">
            <AlertTriangle className="w-3.5 h-3.5 shrink-0" />
            {error}
          </p>
        )}
      </div>
    </div>
  );
}
