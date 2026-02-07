import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Bookmark, BookmarkCheck, AlertCircle } from 'lucide-react';
import { saveToWorkspace } from '../lib/api';
import type { APIError } from '../lib/api';
import { useAuthStore } from '../stores/authStore';

interface SaveToWorkspaceProps {
  itemType: 'transcript' | 'audio' | 'pdf';
  itemId: string;
}

/**
 * Save to Workspace button — shown on transcript/audio/PDF results (MTA-20).
 * Only visible when logged in.
 */
export function SaveToWorkspace({ itemType, itemId }: SaveToWorkspaceProps) {
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated);
  const [saved, setSaved] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!isAuthenticated) return null;

  const handleSave = async () => {
    if (saved || saving) return;
    setSaving(true);
    setError(null);
    try {
      await saveToWorkspace(itemType, itemId);
      setSaved(true);
    } catch (err: unknown) {
      const apiErr = err as APIError;
      setError(apiErr.message || 'Failed to save');
      // Auto-clear error after 3 seconds
      setTimeout(() => setError(null), 3000);
    }
    setSaving(false);
  };

  return (
    <AnimatePresence mode="wait">
      {error ? (
        <motion.div
          key="error"
          initial={{ opacity: 0, scale: 0.9 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={{ opacity: 0, scale: 0.9 }}
          className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium border"
          style={{
            backgroundColor: 'rgba(239, 68, 68, 0.12)',
            borderColor: 'rgba(239, 68, 68, 0.3)',
            color: 'var(--color-error)',
          }}
        >
          <AlertCircle className="w-3.5 h-3.5" />
          {error}
        </motion.div>
      ) : (
        <motion.button
          key={saved ? 'saved' : 'save'}
          initial={{ opacity: 0, scale: 0.9 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={{ opacity: 0, scale: 0.9 }}
          onClick={handleSave}
          disabled={saved || saving}
          className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200 border"
          style={{
            backgroundColor: saved ? 'rgba(24, 185, 133, 0.12)' : 'var(--color-surface)',
            borderColor: saved ? 'rgba(24, 185, 133, 0.3)' : 'var(--color-border)',
            color: saved ? 'var(--color-success)' : 'var(--color-text-secondary)',
          }}
        >
          {saved ? <BookmarkCheck className="w-3.5 h-3.5" /> : <Bookmark className="w-3.5 h-3.5" />}
          {saving ? 'Saving...' : saved ? 'Saved' : 'Save to Workspace'}
        </motion.button>
      )}
    </AnimatePresence>
  );
}
