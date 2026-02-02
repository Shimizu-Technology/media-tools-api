import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Bookmark, BookmarkCheck } from 'lucide-react';
import { saveToWorkspace } from '../lib/api';
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

  if (!isAuthenticated) return null;

  const handleSave = async () => {
    if (saved || saving) return;
    setSaving(true);
    try {
      await saveToWorkspace(itemType, itemId);
      setSaved(true);
    } catch {
      // Error saving
    }
    setSaving(false);
  };

  return (
    <AnimatePresence mode="wait">
      <motion.button
        key={saved ? 'saved' : 'save'}
        initial={{ opacity: 0, scale: 0.9 }}
        animate={{ opacity: 1, scale: 1 }}
        exit={{ opacity: 0, scale: 0.9 }}
        onClick={handleSave}
        disabled={saved || saving}
        className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200 border"
        style={{
          backgroundColor: saved ? 'rgba(34, 197, 94, 0.1)' : 'var(--color-surface)',
          borderColor: saved ? 'rgba(34, 197, 94, 0.3)' : 'var(--color-border)',
          color: saved ? 'rgb(34, 197, 94)' : 'var(--color-text-secondary)',
        }}
      >
        {saved ? <BookmarkCheck className="w-3.5 h-3.5" /> : <Bookmark className="w-3.5 h-3.5" />}
        {saving ? 'Saving...' : saved ? 'Saved' : 'Save to Workspace'}
      </motion.button>
    </AnimatePresence>
  );
}
