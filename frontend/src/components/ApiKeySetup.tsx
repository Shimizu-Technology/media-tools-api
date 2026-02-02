import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
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
  const [existingKey, setExistingKey] = useState('');
  const [createdKey, setCreatedKey] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);

  const handleCreate = async () => {
    setIsLoading(true);
    setError('');
    try {
      const result = await createAPIKey(name);
      if (result.raw_key) {
        setCreatedKey(result.raw_key);
        localStorage.setItem('mta_api_key', result.raw_key);
        onKeySet(result.raw_key);
      }
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to create API key. Is the API server running?');
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
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5, delay: 0.4, ease: [0.22, 1, 0.36, 1] }}
      className="w-full max-w-md mx-auto"
    >
      <div
        className="p-6 rounded-2xl border"
        style={{
          backgroundColor: 'var(--color-surface-elevated)',
          borderColor: 'var(--color-border)',
        }}
      >
        <div className="flex items-center gap-3 mb-4">
          <div
            className="w-10 h-10 rounded-xl flex items-center justify-center"
            style={{ backgroundColor: 'var(--color-brand-100)' }}
          >
            <Key className="w-5 h-5" style={{ color: 'var(--color-brand-600)' }} />
          </div>
          <div>
            <h3 className="text-base font-semibold" style={{ color: 'var(--color-text-primary)' }}>
              API Key Required
            </h3>
            <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
              You need an API key to extract transcripts
            </p>
          </div>
        </div>

        {/* Tab selector */}
        <div className="flex gap-1 p-1 rounded-lg mb-4" style={{ backgroundColor: 'var(--color-surface)' }}>
          {(['create', 'existing'] as const).map((tab) => (
            <button
              key={tab}
              onClick={() => setMode(tab)}
              className="flex-1 py-2 px-3 rounded-md text-sm font-medium transition-colors duration-200"
              style={{
                backgroundColor: mode === tab ? 'var(--color-surface-elevated)' : 'transparent',
                color: mode === tab ? 'var(--color-text-primary)' : 'var(--color-text-muted)',
              }}
            >
              {tab === 'create' ? 'Create New' : 'Use Existing'}
            </button>
          ))}
        </div>

        <AnimatePresence mode="wait">
          {mode === 'create' ? (
            <motion.div key="create" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
              {!createdKey ? (
                <>
                  <input
                    type="text"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    placeholder="Key name (e.g., my-app)"
                    className="w-full px-4 py-3 rounded-xl border text-sm outline-none transition-colors duration-200"
                    style={{
                      backgroundColor: 'var(--color-surface)',
                      borderColor: 'var(--color-border)',
                      color: 'var(--color-text-primary)',
                      minHeight: '44px',
                    }}
                  />
                  <button
                    onClick={handleCreate}
                    disabled={isLoading || !name.trim()}
                    className="w-full mt-3 py-3 rounded-xl text-white font-medium text-sm transition-opacity duration-200 disabled:opacity-50"
                    style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '44px' }}
                  >
                    {isLoading ? 'Creating...' : 'Create API Key'}
                  </button>
                </>
              ) : (
                <div>
                  <div className="flex items-center gap-2 mb-2">
                    <Check className="w-4 h-4 text-green-500" />
                    <span className="text-sm font-medium text-green-500">Key created! Save it now.</span>
                  </div>
                  <div
                    className="flex items-center gap-2 p-3 rounded-lg text-xs font-mono break-all"
                    style={{
                      backgroundColor: 'var(--color-surface)',
                      border: '1px solid var(--color-border)',
                      color: 'var(--color-text-primary)',
                    }}
                  >
                    <span className="flex-1">{createdKey}</span>
                    <button onClick={handleCopy} className="shrink-0 p-1.5 rounded hover:opacity-80">
                      {copied ? <Check className="w-4 h-4 text-green-500" /> : <Copy className="w-4 h-4" style={{ color: 'var(--color-text-muted)' }} />}
                    </button>
                  </div>
                  <div className="flex items-center gap-1.5 mt-2">
                    <AlertTriangle className="w-3.5 h-3.5 text-amber-500" />
                    <span className="text-xs text-amber-500">
                      This key won't be shown again. Copy it somewhere safe.
                    </span>
                  </div>
                </div>
              )}
            </motion.div>
          ) : (
            <motion.div key="existing" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
              <input
                type="text"
                value={existingKey}
                onChange={(e) => setExistingKey(e.target.value)}
                placeholder="mta_abc123..."
                className="w-full px-4 py-3 rounded-xl border text-sm font-mono outline-none transition-colors duration-200"
                style={{
                  backgroundColor: 'var(--color-surface)',
                  borderColor: 'var(--color-border)',
                  color: 'var(--color-text-primary)',
                  minHeight: '44px',
                }}
              />
              <button
                onClick={handleUseExisting}
                disabled={!existingKey.trim()}
                className="w-full mt-3 py-3 rounded-xl text-white font-medium text-sm transition-opacity duration-200 disabled:opacity-50"
                style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '44px' }}
              >
                Use This Key
              </button>
            </motion.div>
          )}
        </AnimatePresence>

        {error && (
          <p className="text-sm text-red-500 mt-3 flex items-center gap-1.5">
            <AlertTriangle className="w-3.5 h-3.5 shrink-0" />
            {error}
          </p>
        )}
      </div>
    </motion.div>
  );
}
