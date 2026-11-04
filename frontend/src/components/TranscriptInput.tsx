import { useState } from 'react';
import { motion } from 'framer-motion';
import { Link, Loader2, ArrowRight } from 'lucide-react';

interface TranscriptInputProps {
  onSubmit: (url: string) => void;
  isLoading: boolean;
}

/**
 * Video URL input with submit button.
 * Supports YouTube, Vimeo, and any yt-dlp-compatible video URL.
 * Mobile-first: 44px min touch targets (Shimizu design guide).
 * Uses Lucide icons, not emoji.
 */
export function TranscriptInput({ onSubmit, isLoading }: TranscriptInputProps) {
  const [url, setUrl] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (url.trim() && !isLoading) {
      onSubmit(url.trim());
    }
  };

  return (
    <motion.form
      onSubmit={handleSubmit}
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.6, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
      className="w-full max-w-2xl mx-auto"
    >
      <div
        className="flex flex-col sm:flex-row gap-3 p-2 rounded-lg border"
        style={{
          backgroundColor: 'var(--color-surface)',
          borderColor: 'var(--color-separator)',
        }}
      >
        {/* URL Input */}
        <div className="relative flex-1">
          <Link
            className="absolute left-4 top-1/2 -translate-y-1/2 w-5 h-5"
            style={{ color: 'var(--color-text-secondary)' }}
          />
          <input
            type="text"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="Paste a video URL (YouTube, Vimeo, etc.)..."
            disabled={isLoading}
            className="w-full pl-12 pr-4 py-3 rounded-md text-base bg-transparent outline-none transition-colors duration-200"
            style={{
              color: 'var(--color-text)',
              minHeight: '44px', // Touch target
            }}
            autoFocus
          />
        </div>

        {/* Submit Button */}
        <motion.button
          type="submit"
          disabled={!url.trim() || isLoading}
          whileHover={{ scale: 1.02 }}
          whileTap={{ scale: 0.98 }}
          className="flex items-center justify-center gap-2 px-6 py-3 rounded-md text-on-accent font-medium text-base transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          style={{
            backgroundColor: 'var(--color-accent-fill)',
            minHeight: '44px', // Touch target
            minWidth: '140px',
          }}
        >
          {isLoading ? (
            <>
              <Loader2 className="w-5 h-5 animate-spin" />
              <span>Extracting...</span>
            </>
          ) : (
            <>
              <span>Extract</span>
              <ArrowRight className="w-4 h-4" />
            </>
          )}
        </motion.button>
      </div>

      <p
        className="text-sm text-center mt-3"
        style={{ color: 'var(--color-text-secondary)' }}
      >
        Supports YouTube, Vimeo, and other video platforms
      </p>
    </motion.form>
  );
}
