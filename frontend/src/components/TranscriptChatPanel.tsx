import { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { MessageSquare, Send, Loader2, AlertCircle, Sparkles } from 'lucide-react';
import { getChat, sendChatMessage, type ChatItemType, type ChatMessage } from '../lib/api';

interface TranscriptChatPanelProps {
  itemId: string;
  itemType: ChatItemType;
}

export function TranscriptChatPanel({ itemId, itemType }: TranscriptChatPanelProps) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const [isLoading, setIsLoading] = useState(true);
  const [isSending, setIsSending] = useState(false);
  const [error, setError] = useState('');
  const endRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const load = async () => {
      setIsLoading(true);
      setError('');
      try {
        const res = await getChat(itemType, itemId);
        setMessages(res.messages || []);
      } catch (err: unknown) {
        const apiErr = err as { message?: string };
        setError(apiErr.message || 'Failed to load chat');
      }
      setIsLoading(false);
    };
    load();
  }, [itemId, itemType]);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, isSending]);

  const handleSend = async () => {
    const text = input.trim();
    if (!text || isSending) return;
    setIsSending(true);
    setError('');
    setInput('');
    try {
      const res = await sendChatMessage(itemType, itemId, text);
      setMessages((prev) => [...prev, ...res.messages]);
    } catch (err: unknown) {
      const apiErr = err as { message?: string };
      setError(apiErr.message || 'Failed to send message');
      setInput(text);
    }
    setIsSending(false);
  };

  return (
    <div className="w-full max-w-2xl mx-auto mt-6">
      <motion.div
        initial={{ opacity: 0, y: 10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.1 }}
        className="flex items-center gap-2 mb-3"
      >
        <MessageSquare className="w-4 h-4" style={{ color: 'var(--color-brand-500)' }} />
        <h3 className="text-sm font-semibold" style={{ color: 'var(--color-text-primary)' }}>
          AI Chat About This Transcript
        </h3>
      </motion.div>

      <div
        className="rounded-2xl border overflow-hidden"
        style={{
          backgroundColor: 'var(--color-surface-elevated)',
          borderColor: 'var(--color-border)',
        }}
      >
        {/* Messages */}
        <div className="p-4 sm:p-6 max-h-[420px] overflow-y-auto space-y-3">
          {isLoading && (
            <div className="flex items-center gap-3 py-6 justify-center">
              <Loader2 className="w-5 h-5 animate-spin" style={{ color: 'var(--color-text-muted)' }} />
              <span className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
                Loading chat…
              </span>
            </div>
          )}

          {!isLoading && messages.length === 0 && (
            <div className="text-center py-8">
              <Sparkles className="w-8 h-8 mx-auto mb-3" style={{ color: 'var(--color-text-muted)' }} />
              <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
                Ask a question about the transcript to start a conversation.
              </p>
            </div>
          )}

          <AnimatePresence>
            {messages.map((m) => {
              const isUser = m.role === 'user';
              return (
                <motion.div
                  key={m.id}
                  initial={{ opacity: 0, y: 6 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: 6 }}
                  className={`flex ${isUser ? 'justify-end' : 'justify-start'}`}
                >
                  <div
                    className="max-w-[85%] sm:max-w-[75%] px-4 py-3 rounded-2xl text-sm leading-relaxed"
                    style={{
                      backgroundColor: isUser ? 'var(--color-brand-500)' : 'var(--color-surface-overlay)',
                      color: isUser ? 'white' : 'var(--color-text-secondary)',
                      border: isUser ? 'none' : '1px solid var(--color-border)',
                    }}
                  >
                    {m.content}
                  </div>
                </motion.div>
              );
            })}
          </AnimatePresence>

          {isSending && (
            <div className="flex justify-start">
              <div
                className="px-4 py-3 rounded-2xl text-sm flex items-center gap-2"
                style={{
                  backgroundColor: 'var(--color-surface-overlay)',
                  color: 'var(--color-text-secondary)',
                  border: '1px solid var(--color-border)',
                }}
              >
                <Loader2 className="w-4 h-4 animate-spin" />
                Thinking…
              </div>
            </div>
          )}

          <div ref={endRef} />
        </div>

        {/* Input */}
        <div
          className="border-t p-3 sm:p-4"
          style={{ borderColor: 'var(--color-border)' }}
        >
          <div className="flex items-end gap-2">
            <textarea
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey) {
                  e.preventDefault();
                  handleSend();
                }
              }}
              placeholder="Ask a question about this transcript…"
              rows={2}
              className="flex-1 resize-none px-4 py-3 rounded-xl border text-sm outline-none transition-colors duration-200"
              style={{
                backgroundColor: 'var(--color-surface-elevated)',
                borderColor: 'var(--color-border)',
                color: 'var(--color-text-primary)',
                minHeight: '44px',
              }}
            />
            <button
              onClick={handleSend}
              disabled={isSending || input.trim() === ''}
              className="flex items-center gap-2 px-4 py-3 rounded-xl text-sm font-medium text-white transition-all duration-200 disabled:opacity-50"
              style={{ backgroundColor: 'var(--color-brand-500)', minHeight: '44px' }}
            >
              <Send className="w-4 h-4" />
              Send
            </button>
          </div>

          {/* Error */}
          {error && (
            <div
              className="flex items-center gap-2 mt-3 p-3 rounded-lg text-sm"
              style={{
                backgroundColor: 'rgba(239, 68, 68, 0.1)',
                border: '1px solid rgba(239, 68, 68, 0.2)',
                color: '#ef4444',
              }}
            >
              <AlertCircle className="w-4 h-4 shrink-0" />
              {error}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
