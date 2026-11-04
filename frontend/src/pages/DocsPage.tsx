import { useState, useCallback } from 'react';
import {
  Copy,
  Check,
  Play,
  Key,
  ArrowRight,
  Loader2,
  AlertCircle,
  CheckCircle,
  ChevronDown,
  ChevronUp,
  Terminal,
  Code,
  Shield,
} from 'lucide-react';
import { createAPIKey, type Transcript } from '../lib/api';

const API_ORIGIN = import.meta.env.VITE_API_URL || window.location.origin;
const API_BASE_EXAMPLE = `${API_ORIGIN}/api/v1`;

/**
 * MTA-15: API Documentation Page.
 * Public-facing docs at /docs with all endpoints, examples, and interactive "Try It".
 */
export function DocsPage() {
  return (
    <div className="mx-auto max-w-4xl px-4 pb-16 pt-10 sm:px-6">
      <header className="mb-10">
        <h1 className="text-large-title">Media Tools API</h1>
        <p className="mt-3 max-w-2xl text-body text-text-secondary">
          Add recordings, video links and PDFs, then read transcripts, summaries and answers from your own scripts or agents. A REST API with API key authentication.
        </p>
      </header>
      <div className="h-px mb-10" style={{ backgroundColor: 'var(--color-separator)' }} />

      {/* Base URL */}
      <Section title="Base URL">
        <CodeBlock code={API_BASE_EXAMPLE} language="text" />
        <p className="text-sm mt-3" style={{ color: 'var(--color-text-secondary)' }}>
          All endpoints are prefixed with <code className="px-1.5 py-0.5 rounded-sm text-xs font-mono" style={{ backgroundColor: 'var(--color-background)', color: 'var(--color-accent-text)' }}>/api/v1</code>.
          Authentication is via the <code className="px-1.5 py-0.5 rounded-sm text-xs font-mono" style={{ backgroundColor: 'var(--color-background)', color: 'var(--color-accent-text)' }}>X-API-Key</code> header.
        </p>
      </Section>

      {/* Get API Key Section */}
      <Section title="Get an API Key">
        <APIKeySignup />
      </Section>

      {/* Endpoints */}
      <Section title="Endpoints">
        <div className="space-y-4">
          <EndpointCard
            method="GET"
            path="/health"
            description="Check API health and status"
            auth={false}
            requestExample={null}
            responseExample={`{
  "status": "ok",
  "version": "1.0.0",
  "database": "unchecked",
  "workers": 4
}`}
          />

          <EndpointCard
            method="GET"
            path="/ready"
            description="Check API and database readiness on demand"
            auth={false}
            requestExample={null}
            responseExample={`{
  "status": "ok",
  "version": "1.0.0",
  "database": "healthy",
  "workers": 4
}`}
          />

          <EndpointCard
            method="POST"
            path="/keys"
            description="Create a new API key"
            auth={false}
            requestExample={`{
  "name": "my-app",
  "rate_limit": 100
}`}
            responseExample={`{
  "id": "uuid",
  "key_prefix": "mta_abc1",
  "name": "my-app",
  "active": true,
  "rate_limit": 100,
  "raw_key": "mta_abc123...xyz"
}`}
          />

          <EndpointCard
            method="POST"
            path="/transcripts"
            description="Submit a YouTube URL for transcript extraction. Returns 202 Accepted — poll GET /transcripts/:id for status."
            auth={true}
            requestExample={`{
  "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
}`}
            responseExample={`{
  "id": "uuid",
  "youtube_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  "youtube_id": "dQw4w9WgXcQ",
  "title": "",
  "status": "pending",
  "created_at": "2026-02-03T00:00:00Z"
}`}
          />

          <EndpointCard
            method="GET"
            path="/transcripts/:id"
            description="Get a single transcript by ID"
            auth={true}
            requestExample={null}
            responseExample={`{
  "id": "uuid",
  "youtube_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  "youtube_id": "dQw4w9WgXcQ",
  "title": "Video Title",
  "channel_name": "Channel",
  "duration": 212,
  "language": "en",
  "transcript_text": "Full transcript text...",
  "word_count": 1500,
  "status": "completed",
  "created_at": "2026-02-03T00:00:00Z",
  "updated_at": "2026-02-03T00:00:30Z"
}`}
          />

          <EndpointCard
            method="GET"
            path="/transcripts"
            description="List transcripts with pagination, filtering, and search. Supports query params: page, per_page, status, search, sort_by, sort_dir, date_from, date_to"
            auth={true}
            requestExample={null}
            responseExample={`{
  "data": [
    { "id": "uuid", "title": "...", "status": "completed", ... }
  ],
  "page": 1,
  "per_page": 20,
  "total_items": 42,
  "total_pages": 3
}`}
          />

          <EndpointCard
            method="POST"
            path="/summaries"
            description="Generate an AI summary for a completed transcript. Returns 202 Accepted — poll GET /transcripts/:id/summaries for result."
            auth={true}
            requestExample={`{
  "transcript_id": "uuid",
  "length": "medium",
  "style": "bullet",
  "model": "openai/gpt-4o"
}`}
            responseExample={`{
  "message": "Summary generation started",
  "transcript_id": "uuid",
  "length": "medium",
  "style": "bullet"
}`}
          />

          <EndpointCard
            method="GET"
            path="/transcripts/:id/summaries"
            description="Get all summaries for a transcript"
            auth={true}
            requestExample={null}
            responseExample={`[
  {
    "id": "uuid",
    "transcript_id": "uuid",
    "model_used": "openai/gpt-4o",
    "summary_text": "The video covers...",
    "key_points": ["Point 1", "Point 2"],
    "length": "medium",
    "style": "bullet",
    "created_at": "2026-02-03T00:01:00Z"
  }
]`}
          />

          <EndpointCard
            method="GET"
            path="/keys"
            description="List your API keys"
            auth={true}
            requestExample={null}
            responseExample={`[
  {
    "id": "uuid",
    "key_prefix": "mta_abc1",
    "name": "my-app",
    "active": true,
    "rate_limit": 100,
    "created_at": "2026-02-03T00:00:00Z"
  }
]`}
          />

          <EndpointCard
            method="DELETE"
            path="/keys/:id"
            description="Revoke an API key"
            auth={true}
            requestExample={null}
            responseExample={`{
  "message": "API key revoked"
}`}
          />
        </div>
      </Section>

      {/* Code Examples */}
      <Section title="Code Examples">
        <CodeExamples />
      </Section>

      {/* Try It */}
      <Section title="Try It">
        <TryItSection />
      </Section>

      {/* Error Responses */}
      <Section title="Error Format">
        <p className="text-sm mb-3" style={{ color: 'var(--color-text-secondary)' }}>
          All errors return a consistent JSON format:
        </p>
        <CodeBlock
          code={`{
  "error": "not_found",
  "message": "Transcript not found",
  "code": 404
}`}
          language="json"
        />
        <div className="mt-4 space-y-2">
          <h3 className="text-sm font-semibold" style={{ color: 'var(--color-text)' }}>
            Common status codes
          </h3>
          <div className="text-sm space-y-1" style={{ color: 'var(--color-text-secondary)' }}>
            <p><strong>200</strong> Success</p>
            <p><strong>202</strong> Accepted (async processing started)</p>
            <p><strong>400</strong> Bad request (invalid parameters)</p>
            <p><strong>401</strong> Unauthorized (missing or invalid API key)</p>
            <p><strong>404</strong> Not found</p>
            <p><strong>429</strong> Rate limited</p>
            <p><strong>500</strong> Server error</p>
          </div>
        </div>
      </Section>

      {/* Rate Limiting */}
      <Section title="Rate Limiting">
        <p className="text-sm mb-3" style={{ color: 'var(--color-text-secondary)' }}>
          API-key limits use one shared request budget. Signed-in browser sessions keep reads and mutations separate so status refreshes cannot block job actions. Check these headers for the applicable budget:
        </p>
        <CodeBlock
          code={`X-RateLimit-Limit: 100
X-RateLimit-Remaining: 97

# Included on 429 responses
Retry-After: 4`}
          language="text"
        />
      </Section>
    </div>
  );
}

// ── Sub-components ──

function Section({ title, children }: { title: string; children: React.ReactNode; delay?: number }) {
  return (
    <section className="mb-12">
      <h2
        className="mb-4 border-b pb-2 text-heading"
        style={{
          color: 'var(--color-text)',
          borderColor: 'var(--color-separator)',
        }}
      >
        {title}
      </h2>
      {children}
    </section>
  );
}

function CodeBlock({ code, language }: { code: string; language: string }) {
  const [copied, setCopied] = useState(false);

  const handleCopy = useCallback(async () => {
    await navigator.clipboard.writeText(code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [code]);

  // Syntax highlighting: method keywords get colored
  const highlighted = language === 'json' || language === 'text'
    ? code
    : code;

  return (
    <div
      className="relative rounded-md border overflow-hidden"
      style={{
        backgroundColor: 'var(--color-background)',
        borderColor: 'var(--color-separator)',
      }}
    >
      <div
        className="flex items-center justify-between px-4 py-2 border-b"
        style={{ borderColor: 'var(--color-separator)' }}
      >
        <span className="text-xs font-mono" style={{ color: 'var(--color-text-secondary)' }}>
          {language}
        </span>
        <button
          onClick={handleCopy}
          className="flex items-center gap-1 px-2 py-1 rounded-sm text-xs transition-colors duration-200 hover:opacity-80"
          style={{ color: copied ? 'var(--color-accent-text)' : 'var(--color-text-secondary)' }}
        >
          {copied ? <Check className="w-3 h-3" /> : <Copy className="w-3 h-3" />}
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
      <pre className="p-4 overflow-x-auto text-sm font-mono leading-relaxed" style={{ color: 'var(--color-text-secondary)' }}>
        {highlighted}
      </pre>
    </div>
  );
}

function EndpointCard({
  method,
  path,
  description,
  auth,
  requestExample,
  responseExample,
}: {
  method: string;
  path: string;
  description: string;
  auth: boolean;
  requestExample: string | null;
  responseExample: string;
}) {
  const [expanded, setExpanded] = useState(false);

  const methodColors: Record<string, { bg: string; text: string }> = {
    GET: { bg: 'var(--color-fill)', text: 'var(--color-text)' },
    POST: { bg: 'var(--color-fill)', text: 'var(--color-text)' },
    DELETE: { bg: 'var(--color-fill)', text: 'var(--color-text)' },
    PUT: { bg: 'var(--color-fill)', text: 'var(--color-text)' },
    PATCH: { bg: 'var(--color-fill)', text: 'var(--color-text)' },
  };

  const colors = methodColors[method] || methodColors.GET;

  return (
    <div
      className="rounded-md border overflow-hidden"
      style={{
        backgroundColor: 'var(--color-surface)',
        borderColor: 'var(--color-separator)',
      }}
    >
      <button
        onClick={() => setExpanded(!expanded)}
        className="w-full flex items-center gap-3 p-4 text-left"
        style={{ minHeight: '52px' }}
      >
        <span
          className="px-2.5 py-1 rounded-sm text-xs font-bold font-mono shrink-0"
          style={{ backgroundColor: colors.bg, color: colors.text }}
        >
          {method}
        </span>
        <span className="text-sm font-mono font-medium" style={{ color: 'var(--color-text)' }}>
          {path}
        </span>
        {auth && (
          <Shield className="w-3.5 h-3.5 shrink-0" style={{ color: 'var(--color-text-secondary)' }} />
        )}
        <span className="flex-1 text-sm truncate ml-2" style={{ color: 'var(--color-text-secondary)' }}>
          {description}
        </span>
        {expanded ? (
          <ChevronUp className="w-4 h-4 shrink-0" style={{ color: 'var(--color-text-secondary)' }} />
        ) : (
          <ChevronDown className="w-4 h-4 shrink-0" style={{ color: 'var(--color-text-secondary)' }} />
        )}
      </button>

      {expanded && (
          <div>
            <div className="px-4 pb-4 space-y-3" style={{ borderTop: '1px solid var(--color-separator)' }}>
              <div className="pt-3">
                <p className="text-sm mb-3" style={{ color: 'var(--color-text-secondary)' }}>
                  {description}
                </p>
                {auth && (
                  <div className="flex items-center gap-1.5 text-xs mb-3" style={{ color: 'var(--color-text-secondary)' }}>
                    <Shield className="w-3 h-3" />
                    Requires API key authentication
                  </div>
                )}
              </div>

              {requestExample && (
                <div>
                  <h3 className="text-xs font-semibold mb-2" style={{ color: 'var(--color-text-secondary)' }}>
                    Request Body
                  </h3>
                  <CodeBlock code={requestExample} language="json" />
                </div>
              )}

              <div>
                <h3 className="text-xs font-semibold mb-2" style={{ color: 'var(--color-text-secondary)' }}>
                  Response
                </h3>
                <CodeBlock code={responseExample} language="json" />
              </div>
            </div>
          </div>
        )}
    </div>
  );
}

function CodeExamples() {
  type TabKey = 'curl' | 'javascript' | 'python';
  const [activeTab, setActiveTab] = useState<TabKey>('curl');

  const examples: Record<TabKey, { label: string; icon: React.ReactNode; code: string }> = {
    curl: {
      label: 'cURL',
      icon: <Terminal className="w-4 h-4" />,
      code: `# Create an API key
curl -X POST ${API_ORIGIN}/api/v1/keys \\
  -H "Content-Type: application/json" \\
  -H "X-Admin-Key: YOUR_ADMIN_KEY" \\
  -d '{"name": "my-app"}'

# Extract a transcript
curl -X POST ${API_ORIGIN}/api/v1/transcripts \\
  -H "Content-Type: application/json" \\
  -H "X-API-Key: YOUR_API_KEY" \\
  -d '{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}'

# Check transcript status
curl ${API_ORIGIN}/api/v1/transcripts/TRANSCRIPT_ID \\
  -H "X-API-Key: YOUR_API_KEY"

# Generate AI summary
curl -X POST ${API_ORIGIN}/api/v1/summaries \\
  -H "Content-Type: application/json" \\
  -H "X-API-Key: YOUR_API_KEY" \\
  -d '{"transcript_id": "TRANSCRIPT_ID", "length": "medium"}'`,
    },
    javascript: {
      label: 'JavaScript',
      icon: <Code className="w-4 h-4" />,
      code: `const API_BASE = '${API_ORIGIN}/api/v1';
const API_KEY = 'YOUR_API_KEY';

// Extract a transcript
const res = await fetch(\`\${API_BASE}/transcripts\`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-API-Key': API_KEY,
  },
  body: JSON.stringify({
    url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
  }),
});
const transcript = await res.json();
console.log('Transcript ID:', transcript.id);

// Poll until complete
const poll = async (id) => {
  const res = await fetch(\`\${API_BASE}/transcripts/\${id}\`, {
    headers: { 'X-API-Key': API_KEY },
  });
  const data = await res.json();
  if (data.status === 'completed') return data;
  if (data.status === 'failed') throw new Error(data.error_message);
  await new Promise((r) => setTimeout(r, 2000));
  return poll(id);
};

const completed = await poll(transcript.id);
console.log('Words:', completed.word_count);
console.log('Transcript:', completed.transcript_text);`,
    },
    python: {
      label: 'Python',
      icon: <Code className="w-4 h-4" />,
      code: `import requests
import time

API_BASE = '${API_ORIGIN}/api/v1'
API_KEY = 'YOUR_API_KEY'
headers = {
    'Content-Type': 'application/json',
    'X-API-Key': API_KEY,
}

# Extract a transcript
res = requests.post(f'{API_BASE}/transcripts', json={
    'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
}, headers=headers)
transcript = res.json()
print(f'Transcript ID: {transcript["id"]}')

# Poll until complete
while transcript['status'] in ('pending', 'processing'):
    time.sleep(2)
    res = requests.get(
        f'{API_BASE}/transcripts/{transcript["id"]}',
        headers=headers,
    )
    transcript = res.json()

print(f'Words: {transcript["word_count"]}')
print(f'Transcript: {transcript["transcript_text"][:200]}...')`,
    },
  };

  return (
    <div>
      {/* Language tabs */}
      <div className="flex gap-1 p-1 rounded-md mb-3" style={{ backgroundColor: 'var(--color-background)' }}>
        {(['curl', 'javascript', 'python'] as const).map((key) => (
          <button
            key={key}
            onClick={() => setActiveTab(key)}
            className="flex items-center gap-2 px-4 py-2 rounded-sm text-sm font-medium transition-colors duration-200"
            style={{
              backgroundColor: activeTab === key ? 'var(--color-surface)' : 'transparent',
              color: activeTab === key ? 'var(--color-text)' : 'var(--color-text-secondary)',
              minHeight: '44px',
            }}
          >
            {examples[key].icon}
            {examples[key].label}
          </button>
        ))}
      </div>

      <CodeBlock code={examples[activeTab].code} language={activeTab} />
    </div>
  );
}

function APIKeySignup() {
  const [name, setName] = useState('my-app');
  const [adminKey, setAdminKey] = useState('');
  const [isCreating, setIsCreating] = useState(false);
  const [createdKey, setCreatedKey] = useState('');
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);

  const handleCreate = async () => {
    setIsCreating(true);
    setError('');
    try {
      const result = await createAPIKey(name, { adminKey: adminKey.trim() || undefined });
      if (result.raw_key) {
        setCreatedKey(result.raw_key);
      }
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to create API key. Is the server running?');
    }
    setIsCreating(false);
  };

  const handleCopy = async () => {
    await navigator.clipboard.writeText(createdKey);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  if (createdKey) {
    return (
      <div
        className="p-4 rounded-md border"
        style={{
          backgroundColor: 'var(--color-surface)',
          borderColor: 'var(--color-separator)',
        }}
      >
        <div className="flex items-center gap-2 mb-3">
          <CheckCircle className="w-4 h-4 text-accent-text" />
          <span className="text-sm font-medium text-accent-text">API key created!</span>
        </div>
        <div
          className="flex items-center gap-2 p-3 rounded-sm text-xs font-mono break-all"
          style={{
            backgroundColor: 'var(--color-background)',
            border: '1px solid var(--color-separator)',
            color: 'var(--color-text)',
          }}
        >
          <span className="flex-1">{createdKey}</span>
          <button onClick={handleCopy} className="shrink-0 p-1.5 rounded-sm hover:opacity-80">
            {copied ? <Check className="w-4 h-4 text-accent-text" /> : <Copy className="w-4 h-4" style={{ color: 'var(--color-text-secondary)' }} />}
          </button>
        </div>
        <p className="text-xs mt-2" style={{ color: 'var(--color-text-secondary)' }}>
          Save this key securely. It won&apos;t be shown again.
        </p>
      </div>
    );
  }

  return (
    <div
      className="p-4 rounded-md border"
      style={{
        backgroundColor: 'var(--color-surface)',
        borderColor: 'var(--color-separator)',
      }}
    >
      <div className="flex items-center gap-3 mb-3">
        <Key className="w-5 h-5" style={{ color: 'var(--color-accent-text)' }} />
        <span className="text-sm font-medium" style={{ color: 'var(--color-text)' }}>
          Create a developer API key
        </span>
      </div>
      <div className="grid gap-3 sm:grid-cols-[1fr_1fr_auto]">
        <input
          type="password"
          value={adminKey}
          onChange={(e) => setAdminKey(e.target.value)}
          placeholder="Admin key (production)"
          className="px-4 py-2.5 rounded-md border text-sm outline-none transition-colors duration-200"
          style={{
            backgroundColor: 'var(--color-background)',
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
          className="flex-1 px-4 py-2.5 rounded-md border text-sm outline-none transition-colors duration-200"
          style={{
            backgroundColor: 'var(--color-background)',
            borderColor: 'var(--color-separator)',
            color: 'var(--color-text)',
            minHeight: '44px',
          }}
        />
        <button
          onClick={handleCreate}
          disabled={isCreating || !name.trim()}
          className="flex items-center gap-2 px-5 py-2.5 rounded-md text-on-accent font-medium text-sm transition-colors disabled:opacity-50"
          style={{ backgroundColor: 'var(--color-accent-fill)', minHeight: '44px' }}
        >
          {isCreating ? <Loader2 className="w-4 h-4 animate-spin" /> : <Key className="w-4 h-4" />}
          Create Key
        </button>
      </div>
      <p className="text-xs mt-2" style={{ color: 'var(--color-text-secondary)' }}>
        Production requires an admin key; local development can leave it blank.
      </p>
      {error && (
        <p className="flex items-center gap-1.5 text-xs text-danger mt-2">
          <AlertCircle className="w-3 h-3" />
          {error}
        </p>
      )}
    </div>
  );
}

function TryItSection() {
  const [url, setUrl] = useState('');
  const [apiKey, setApiKey] = useState(() => localStorage.getItem('mta_api_key') || '');
  const [result, setResult] = useState<Transcript | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');

  const handleTry = async () => {
    if (!url.trim() || !apiKey.trim()) return;
    setIsLoading(true);
    setError('');
    setResult(null);

    try {
      const res = await fetch(`${API_ORIGIN}/api/v1/transcripts`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': apiKey.trim(),
        },
        body: JSON.stringify({ url: url.trim() }),
      });
      if (!res.ok) {
        const apiErr = await res.json().catch(() => ({ message: `HTTP ${res.status}` }));
        throw apiErr;
      }
      const transcript = await res.json() as Transcript;
      setResult(transcript);
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Request failed');
    }

    setIsLoading(false);
  };

  return (
    <div
      className="p-6 rounded-lg border"
      style={{
        backgroundColor: 'var(--color-surface)',
        borderColor: 'var(--color-separator)',
      }}
    >
      <div className="flex items-center gap-2 mb-4">
        <Play className="w-5 h-5" style={{ color: 'var(--color-accent-text)' }} />
        <h3 className="text-base font-semibold" style={{ color: 'var(--color-text)' }}>
          Test the API
        </h3>
      </div>

      <div className="space-y-3">
        <div>
          <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--color-text-secondary)' }}>
            API Key
          </label>
          <input
            type="text"
            value={apiKey}
            onChange={(e) => setApiKey(e.target.value)}
            placeholder="mta_abc123..."
            className="w-full px-4 py-2.5 rounded-md border text-sm font-mono outline-none transition-colors duration-200"
            style={{
              backgroundColor: 'var(--color-background)',
              borderColor: 'var(--color-separator)',
              color: 'var(--color-text)',
              minHeight: '44px',
            }}
          />
        </div>

        <div>
          <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--color-text-secondary)' }}>
            YouTube URL
          </label>
          <input
            type="text"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="https://www.youtube.com/watch?v=..."
            className="w-full px-4 py-2.5 rounded-md border text-sm outline-none transition-colors duration-200"
            style={{
              backgroundColor: 'var(--color-background)',
              borderColor: 'var(--color-separator)',
              color: 'var(--color-text)',
              minHeight: '44px',
            }}
          />
        </div>

        <button
          onClick={handleTry}
          disabled={isLoading || !url.trim() || !apiKey.trim()}
          className="flex items-center gap-2 px-5 py-2.5 rounded-md text-on-accent font-medium text-sm transition-colors disabled:opacity-50"
          style={{ backgroundColor: 'var(--color-accent-fill)', minHeight: '44px' }}
        >
          {isLoading ? (
            <>
              <Loader2 className="w-4 h-4 animate-spin" />
              Requesting...
            </>
          ) : (
            <>
              <ArrowRight className="w-4 h-4" />
              Send Request
            </>
          )}
        </button>
      </div>

      {/* Result */}
      {result && (
        <div className="mt-4">
          <h3 className="text-xs font-semibold mb-2" style={{ color: 'var(--color-text-secondary)' }}>
            Response (202 Accepted)
          </h3>
          <CodeBlock code={JSON.stringify(result, null, 2)} language="json" />
        </div>
      )}

      {error && (
        <div className="mt-4 flex items-center gap-2 rounded-md bg-fill p-3 text-callout" role="alert">
          <AlertCircle className="w-4 h-4 shrink-0" />
          {error}
        </div>
      )}
    </div>
  );
}
