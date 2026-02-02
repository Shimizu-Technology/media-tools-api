import { useState, useEffect } from 'react';
import { motion } from 'framer-motion';
import { Layout, FileText, Mic, FileType2, Trash2, ExternalLink, Clock } from 'lucide-react';
import { getWorkspace, removeFromWorkspace } from '../lib/api';
import type { WorkspaceResponse } from '../lib/api';

/**
 * Workspace page — Shows user's saved transcripts, audio, and PDFs (MTA-20).
 */
export function WorkspacePage() {
  const [workspace, setWorkspace] = useState<WorkspaceResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<'transcript' | 'audio' | 'pdf'>('transcript');

  useEffect(() => {
    loadWorkspace();
  }, []);

  const loadWorkspace = async () => {
    try {
      const data = await getWorkspace();
      setWorkspace(data);
    } catch {
      // Not logged in or error
    }
    setLoading(false);
  };

  const handleRemove = async (itemType: string, itemId: string) => {
    try {
      await removeFromWorkspace(itemType, itemId);
      await loadWorkspace();
    } catch {
      // Silently fail
    }
  };

  const tabs = [
    { id: 'transcript' as const, label: 'Transcripts', icon: FileText, count: workspace?.transcripts.length ?? 0 },
    { id: 'audio' as const, label: 'Audio', icon: Mic, count: workspace?.audio.length ?? 0 },
    { id: 'pdf' as const, label: 'PDFs', icon: FileType2, count: workspace?.pdfs.length ?? 0 },
  ];

  const formatDate = (dateStr: string) => {
    return new Date(dateStr).toLocaleDateString('en-US', {
      month: 'short', day: 'numeric', year: 'numeric',
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
          className="mb-8"
        >
          <div className="flex items-center gap-3 mb-2">
            <Layout className="w-6 h-6" style={{ color: 'var(--color-brand-500)' }} />
            <h1 className="text-2xl font-bold" style={{ color: 'var(--color-text-primary)' }}>
              Workspace
            </h1>
          </div>
          <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
            Your saved transcripts, audio transcriptions, and PDF extractions.
          </p>
        </motion.div>

        {/* Tabs */}
        <div className="flex gap-1 rounded-xl p-1 mb-6" style={{ backgroundColor: 'var(--color-surface-elevated)' }}>
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className="flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-medium transition-all duration-200"
              style={{
                backgroundColor: activeTab === tab.id ? 'var(--color-brand-500)' : 'transparent',
                color: activeTab === tab.id ? 'white' : 'var(--color-text-secondary)',
              }}
            >
              <tab.icon className="w-4 h-4" />
              <span className="hidden sm:inline">{tab.label}</span>
              {tab.count > 0 && (
                <span
                  className="text-xs px-1.5 py-0.5 rounded-full"
                  style={{
                    backgroundColor: activeTab === tab.id ? 'rgba(255,255,255,0.2)' : 'var(--color-surface)',
                  }}
                >
                  {tab.count}
                </span>
              )}
            </button>
          ))}
        </div>

        {/* Content */}
        {loading ? (
          <div className="text-center py-12" style={{ color: 'var(--color-text-muted)' }}>
            Loading workspace...
          </div>
        ) : (
          <motion.div
            key={activeTab}
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.3 }}
            className="space-y-3"
          >
            {activeTab === 'transcript' && workspace?.transcripts.map((t) => (
              <div
                key={t.id}
                className="rounded-xl border p-4 flex items-center justify-between gap-4"
                style={{
                  backgroundColor: 'var(--color-surface-elevated)',
                  borderColor: 'var(--color-border)',
                }}
              >
                <div className="min-w-0 flex-1">
                  <h3 className="font-medium text-sm truncate" style={{ color: 'var(--color-text-primary)' }}>
                    {t.title || 'Untitled'}
                  </h3>
                  <div className="flex items-center gap-3 mt-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>
                    <span>{t.channel_name}</span>
                    <span className="flex items-center gap-1"><Clock className="w-3 h-3" />{formatDate(t.created_at)}</span>
                    <span>{t.word_count.toLocaleString()} words</span>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <a
                    href={`/?id=${t.id}`}
                    className="p-2 rounded-lg transition-colors hover:opacity-80"
                    style={{ color: 'var(--color-brand-500)' }}
                    title="View transcript"
                  >
                    <ExternalLink className="w-4 h-4" />
                  </a>
                  <button
                    onClick={() => handleRemove('transcript', t.id)}
                    className="p-2 rounded-lg transition-colors hover:opacity-80 text-red-500"
                    title="Remove from workspace"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </div>
              </div>
            ))}

            {activeTab === 'audio' && workspace?.audio.map((a) => (
              <div
                key={a.id}
                className="rounded-xl border p-4 flex items-center justify-between gap-4"
                style={{
                  backgroundColor: 'var(--color-surface-elevated)',
                  borderColor: 'var(--color-border)',
                }}
              >
                <div className="min-w-0 flex-1">
                  <h3 className="font-medium text-sm truncate" style={{ color: 'var(--color-text-primary)' }}>
                    {a.original_name}
                  </h3>
                  <div className="flex items-center gap-3 mt-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>
                    <span>{a.language || 'Unknown'}</span>
                    <span className="flex items-center gap-1"><Clock className="w-3 h-3" />{formatDate(a.created_at)}</span>
                    <span>{a.word_count.toLocaleString()} words</span>
                  </div>
                </div>
                <button
                  onClick={() => handleRemove('audio', a.id)}
                  className="p-2 rounded-lg transition-colors hover:opacity-80 text-red-500"
                  title="Remove from workspace"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            ))}

            {activeTab === 'pdf' && workspace?.pdfs.map((p) => (
              <div
                key={p.id}
                className="rounded-xl border p-4 flex items-center justify-between gap-4"
                style={{
                  backgroundColor: 'var(--color-surface-elevated)',
                  borderColor: 'var(--color-border)',
                }}
              >
                <div className="min-w-0 flex-1">
                  <h3 className="font-medium text-sm truncate" style={{ color: 'var(--color-text-primary)' }}>
                    {p.original_name}
                  </h3>
                  <div className="flex items-center gap-3 mt-1 text-xs" style={{ color: 'var(--color-text-muted)' }}>
                    <span>{p.page_count} pages</span>
                    <span className="flex items-center gap-1"><Clock className="w-3 h-3" />{formatDate(p.created_at)}</span>
                    <span>{p.word_count.toLocaleString()} words</span>
                  </div>
                </div>
                <button
                  onClick={() => handleRemove('pdf', p.id)}
                  className="p-2 rounded-lg transition-colors hover:opacity-80 text-red-500"
                  title="Remove from workspace"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            ))}

            {/* Empty state */}
            {((activeTab === 'transcript' && (!workspace?.transcripts.length)) ||
              (activeTab === 'audio' && (!workspace?.audio.length)) ||
              (activeTab === 'pdf' && (!workspace?.pdfs.length))) && (
              <div className="text-center py-12" style={{ color: 'var(--color-text-muted)' }}>
                <p className="text-sm">No saved items yet. Use the &quot;Save to Workspace&quot; button on results.</p>
              </div>
            )}
          </motion.div>
        )}
      </div>
    </main>
  );
}
