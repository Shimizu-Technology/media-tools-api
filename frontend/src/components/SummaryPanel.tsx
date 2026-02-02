import { useState, useEffect, useCallback, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Sparkles,
  List,
  FileText,
  Loader2,
  ChevronDown,
  RefreshCw,
  AlertCircle,
} from 'lucide-react';
import { createSummary, getSummaries, type Summary } from '../lib/api';

interface SummaryPanelProps {
  transcriptId: string;
  transcriptText: string;
}

type TabId = 'transcript' | 'key_points' | 'summary';

/**
 * MTA-14: AI Summary Panel.
 * Tabbed view for Full Transcript, Key Points, and Summary.
 * Typewriter effect for streaming feel. Summary length picker.
 */
export function SummaryPanel({ transcriptId, transcriptText }: SummaryPanelProps) {
  const [activeTab, setActiveTab] = useState<TabId>('transcript');
  const [summary, setSummary] = useState<Summary | null>(null);
  const [isGenerating, setIsGenerating] = useState(false);
  const [isLoadingSummaries, setIsLoadingSummaries] = useState(false);
  const [error, setError] = useState('');
  const [summaryLength, setSummaryLength] = useState<string>('medium');
  const [showLengthMenu, setShowLengthMenu] = useState(false);
  const [typedText, setTypedText] = useState('');
  const [typedKeyPoints, setTypedKeyPoints] = useState<string[]>([]);
  const [isTyping, setIsTyping] = useState(false);
  const typeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pollTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const tabs: { id: TabId; label: string; icon: React.ReactNode }[] = [
    { id: 'transcript', label: 'Full Transcript', icon: <FileText className="w-4 h-4" /> },
    { id: 'key_points', label: 'Key Points', icon: <List className="w-4 h-4" /> },
    { id: 'summary', label: 'Summary', icon: <Sparkles className="w-4 h-4" /> },
  ];

  const lengthOptions = [
    { value: 'short', label: 'Brief', desc: 'Quick overview' },
    { value: 'medium', label: 'Standard', desc: 'Balanced detail' },
    { value: 'detailed', label: 'Detailed', desc: 'Comprehensive analysis' },
  ];

  // Load existing summaries on mount
  useEffect(() => {
    const loadSummaries = async () => {
      setIsLoadingSummaries(true);
      try {
        const summaries = await getSummaries(transcriptId);
        if (summaries.length > 0) {
          // Use the most recent summary
          const latest = summaries[summaries.length - 1];
          setSummary(latest);
        }
      } catch {
        // No summaries yet — that's fine
      }
      setIsLoadingSummaries(false);
    };
    loadSummaries();
  }, [transcriptId]);

  // Typewriter effect for summary text
  const startTypewriter = useCallback((text: string, keyPoints: string[]) => {
    setIsTyping(true);
    setTypedText('');
    setTypedKeyPoints([]);

    let charIndex = 0;
    const speed = 12; // ms per character

    const typeNextChar = () => {
      if (charIndex < text.length) {
        setTypedText(text.slice(0, charIndex + 1));
        charIndex++;
        typeTimerRef.current = setTimeout(typeNextChar, speed);
      } else {
        // Now type key points one by one
        let pointIndex = 0;
        const typeNextPoint = () => {
          if (pointIndex < keyPoints.length) {
            setTypedKeyPoints((prev) => [...prev, keyPoints[pointIndex]]);
            pointIndex++;
            typeTimerRef.current = setTimeout(typeNextPoint, 150);
          } else {
            setIsTyping(false);
          }
        };
        typeNextPoint();
      }
    };

    typeTimerRef.current = setTimeout(typeNextChar, speed);
  }, []);

  // Cleanup timers
  useEffect(() => {
    return () => {
      if (typeTimerRef.current) clearTimeout(typeTimerRef.current);
      if (pollTimerRef.current) clearTimeout(pollTimerRef.current);
    };
  }, []);

  const handleGenerateSummary = async () => {
    setIsGenerating(true);
    setError('');
    setSummary(null);
    setTypedText('');
    setTypedKeyPoints([]);
    setActiveTab('summary');

    try {
      await createSummary(transcriptId, {
        length: summaryLength,
        style: 'bullet',
      });

      // Poll for the summary to complete
      const pollForSummary = async (attempts: number) => {
        if (attempts > 30) {
          setError('Summary generation timed out. Please try again.');
          setIsGenerating(false);
          return;
        }

        try {
          const summaries = await getSummaries(transcriptId);
          if (summaries.length > 0) {
            const latest = summaries[summaries.length - 1];
            if (latest.summary_text) {
              setSummary(latest);
              setIsGenerating(false);
              // Parse key points
              let keyPoints: string[] = [];
              try {
                const parsed: unknown = JSON.parse(latest.key_points as unknown as string);
                if (Array.isArray(parsed)) keyPoints = parsed as string[];
              } catch {
                if (Array.isArray(latest.key_points)) {
                  keyPoints = latest.key_points as unknown as string[];
                }
              }
              startTypewriter(latest.summary_text, keyPoints);
              return;
            }
          }
        } catch {
          // Keep polling
        }
        pollTimerRef.current = setTimeout(() => pollForSummary(attempts + 1), 2000);
      };

      pollForSummary(0);
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to generate summary');
      setIsGenerating(false);
    }
  };

  const parsedKeyPoints = (() => {
    if (!summary) return [];
    try {
      const raw = summary.key_points;
      if (typeof raw === 'string') {
        const parsed: unknown = JSON.parse(raw);
        if (Array.isArray(parsed)) return parsed as string[];
      }
      if (Array.isArray(raw)) return raw as unknown as string[];
    } catch {
      // ignore
    }
    return [];
  })();

  const hasSummary = !!summary;

  return (
    <div className="w-full max-w-2xl mx-auto mt-4">
      {/* Generate Summary Button + Length Picker */}
      <motion.div
        initial={{ opacity: 0, y: 10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.2 }}
        className="flex items-center gap-3 mb-4"
      >
        <button
          onClick={handleGenerateSummary}
          disabled={isGenerating}
          className="flex items-center gap-2 px-5 py-2.5 rounded-xl font-medium text-sm text-white transition-all duration-200 hover:opacity-90 disabled:opacity-50"
          style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '44px' }}
        >
          {isGenerating ? (
            <>
              <Loader2 className="w-4 h-4 animate-spin" />
              Generating...
            </>
          ) : hasSummary ? (
            <>
              <RefreshCw className="w-4 h-4" />
              Regenerate Summary
            </>
          ) : (
            <>
              <Sparkles className="w-4 h-4" />
              Generate AI Summary
            </>
          )}
        </button>

        {/* Length Dropdown */}
        <div className="relative">
          <button
            onClick={() => setShowLengthMenu(!showLengthMenu)}
            className="flex items-center gap-2 px-4 py-2.5 rounded-xl border text-sm font-medium transition-colors duration-200"
            style={{
              backgroundColor: 'var(--color-surface-elevated)',
              borderColor: 'var(--color-border)',
              color: 'var(--color-text-secondary)',
              minHeight: '44px',
            }}
          >
            {lengthOptions.find((o) => o.value === summaryLength)?.label || 'Standard'}
            <ChevronDown className="w-3.5 h-3.5" />
          </button>

          <AnimatePresence>
            {showLengthMenu && (
              <motion.div
                initial={{ opacity: 0, y: 4, scale: 0.95 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                exit={{ opacity: 0, y: 4, scale: 0.95 }}
                transition={{ duration: 0.15 }}
                className="absolute top-full left-0 mt-1.5 w-52 rounded-xl border shadow-lg overflow-hidden z-20"
                style={{
                  backgroundColor: 'var(--color-surface-overlay)',
                  borderColor: 'var(--color-border)',
                }}
              >
                {lengthOptions.map((opt) => (
                  <button
                    key={opt.value}
                    onClick={() => {
                      setSummaryLength(opt.value);
                      setShowLengthMenu(false);
                    }}
                    className="w-full px-4 py-3 text-left transition-colors duration-150 hover:brightness-95"
                    style={{
                      backgroundColor: summaryLength === opt.value ? 'var(--color-surface-elevated)' : 'transparent',
                      minHeight: '44px',
                    }}
                  >
                    <div className="text-sm font-medium" style={{ color: 'var(--color-text-primary)' }}>
                      {opt.label}
                    </div>
                    <div className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
                      {opt.desc}
                    </div>
                  </button>
                ))}
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </motion.div>

      {/* Tabbed View */}
      <div
        className="rounded-2xl border overflow-hidden"
        style={{
          backgroundColor: 'var(--color-surface-elevated)',
          borderColor: 'var(--color-border)',
        }}
      >
        {/* Tab Bar */}
        <div
          className="flex border-b"
          style={{ borderColor: 'var(--color-border)' }}
        >
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className="relative flex items-center gap-2 px-4 py-3 text-sm font-medium transition-colors duration-200"
              style={{
                color: activeTab === tab.id ? 'var(--color-brand-500)' : 'var(--color-text-muted)',
                minHeight: '44px',
              }}
            >
              {tab.icon}
              <span className="hidden sm:inline">{tab.label}</span>
              {activeTab === tab.id && (
                <motion.div
                  layoutId="summaryTab"
                  className="absolute bottom-0 left-0 right-0 h-0.5"
                  style={{ backgroundColor: 'var(--color-brand-500)' }}
                  transition={{ type: 'spring', stiffness: 400, damping: 30 }}
                />
              )}
            </button>
          ))}
        </div>

        {/* Tab Content */}
        <div className="p-6">
          <AnimatePresence mode="wait">
            {/* Full Transcript Tab */}
            {activeTab === 'transcript' && (
              <motion.div
                key="transcript"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -8 }}
                transition={{ duration: 0.2 }}
                className="text-sm leading-relaxed whitespace-pre-wrap max-h-[60vh] overflow-y-auto"
                style={{ color: 'var(--color-text-secondary)' }}
              >
                {transcriptText}
              </motion.div>
            )}

            {/* Key Points Tab */}
            {activeTab === 'key_points' && (
              <motion.div
                key="key_points"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -8 }}
                transition={{ duration: 0.2 }}
              >
                {isGenerating && (
                  <div className="flex items-center gap-3 py-8 justify-center">
                    <Loader2 className="w-5 h-5 animate-spin" style={{ color: 'var(--color-brand-500)' }} />
                    <span className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
                      Analyzing key points...
                    </span>
                  </div>
                )}

                {isLoadingSummaries && !isGenerating && (
                  <div className="flex items-center gap-3 py-8 justify-center">
                    <Loader2 className="w-5 h-5 animate-spin" style={{ color: 'var(--color-text-muted)' }} />
                  </div>
                )}

                {!isGenerating && !isLoadingSummaries && parsedKeyPoints.length === 0 && !isTyping && (
                  <div className="text-center py-8">
                    <List className="w-8 h-8 mx-auto mb-3" style={{ color: 'var(--color-text-muted)' }} />
                    <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
                      Generate a summary to see key points extracted from the transcript.
                    </p>
                  </div>
                )}

                {/* Show typed key points or all if typing is done */}
                {(isTyping ? typedKeyPoints : parsedKeyPoints).length > 0 && (
                  <ul className="space-y-3">
                    {(isTyping ? typedKeyPoints : parsedKeyPoints).map((point, i) => (
                      <motion.li
                        key={i}
                        initial={{ opacity: 0, x: -10 }}
                        animate={{ opacity: 1, x: 0 }}
                        transition={{ duration: 0.3, delay: isTyping ? 0 : i * 0.05 }}
                        className="flex items-start gap-3 text-sm"
                      >
                        <span
                          className="flex-shrink-0 w-6 h-6 rounded-lg flex items-center justify-center text-xs font-semibold mt-0.5"
                          style={{
                            backgroundColor: 'var(--color-brand-500)',
                            color: 'white',
                          }}
                        >
                          {i + 1}
                        </span>
                        <span style={{ color: 'var(--color-text-secondary)' }}>{point}</span>
                      </motion.li>
                    ))}
                  </ul>
                )}
              </motion.div>
            )}

            {/* Summary Tab */}
            {activeTab === 'summary' && (
              <motion.div
                key="summary"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -8 }}
                transition={{ duration: 0.2 }}
              >
                {isGenerating && (
                  <div className="flex flex-col items-center gap-3 py-8">
                    <Loader2 className="w-6 h-6 animate-spin" style={{ color: 'var(--color-brand-500)' }} />
                    <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
                      AI is generating your summary...
                    </p>
                    <p className="text-xs" style={{ color: 'var(--color-text-muted)' }}>
                      This usually takes 15-30 seconds
                    </p>
                  </div>
                )}

                {!isGenerating && !summary && !isLoadingSummaries && (
                  <div className="text-center py-8">
                    <Sparkles className="w-8 h-8 mx-auto mb-3" style={{ color: 'var(--color-text-muted)' }} />
                    <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
                      Click "Generate AI Summary" to create an intelligent summary of this transcript.
                    </p>
                  </div>
                )}

                {/* Summary text with typewriter effect */}
                {(isTyping ? typedText : summary?.summary_text) && (
                  <div
                    className="text-sm leading-relaxed whitespace-pre-wrap"
                    style={{ color: 'var(--color-text-secondary)' }}
                  >
                    {isTyping ? typedText : summary?.summary_text}
                    {isTyping && (
                      <motion.span
                        animate={{ opacity: [1, 0] }}
                        transition={{ duration: 0.5, repeat: Infinity, repeatType: 'reverse' }}
                        className="inline-block w-0.5 h-4 ml-0.5 align-middle"
                        style={{ backgroundColor: 'var(--color-brand-500)' }}
                      />
                    )}
                  </div>
                )}

                {/* Model info */}
                {summary && !isTyping && (
                  <div
                    className="mt-4 pt-4 flex items-center gap-2 text-xs"
                    style={{
                      borderTop: '1px solid var(--color-border)',
                      color: 'var(--color-text-muted)',
                    }}
                  >
                    <Sparkles className="w-3 h-3" />
                    Generated by {summary.model_used} &middot; {summary.length} length
                  </div>
                )}
              </motion.div>
            )}
          </AnimatePresence>

          {/* Error */}
          {error && (
            <motion.div
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              className="flex items-center gap-2 mt-4 p-3 rounded-lg text-sm"
              style={{
                backgroundColor: 'rgba(239, 68, 68, 0.1)',
                border: '1px solid rgba(239, 68, 68, 0.2)',
                color: '#ef4444',
              }}
            >
              <AlertCircle className="w-4 h-4 shrink-0" />
              {error}
            </motion.div>
          )}
        </div>
      </div>
    </div>
  );
}
