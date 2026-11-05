import { useEffect, useLayoutEffect, useRef, useState, type FormEvent } from 'react';
import { ArrowUp, Loader2 } from 'lucide-react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import rehypeSanitize from 'rehype-sanitize';
import { useNavigate } from 'react-router-dom';
import { CitationRow } from './CitationChip';
import { getChat, getErrorMessage, sendChatMessage, type ChatItemType, type ChatMessage, type Citation } from '../lib/api';
import { itemDetailPath } from '../lib/library';
import { useAIProcessingConsent } from '../contexts/useAIProcessingConsent';
import { AIContentReportButton } from './AIContentReportButton';
import { Notice } from './ui/Field';

/**
 * Questions and answers about one item or collection. The conversation
 * scrolls inside its own box, and only when a new message arrives: opening an
 * item never moves the page.
 */
export function ChatPanel({ itemId, itemType, placeholder, onCitationClick, autoFocus = false, fill = false }: {
  itemId: string;
  itemType: ChatItemType;
  placeholder: string;
  onCitationClick?: (citation: Citation) => void;
  autoFocus?: boolean;
  /** Grow to the container's height (sheet, side panel) instead of a fixed box. */
  fill?: boolean;
}) {
  const { requestConsent } = useAIProcessingConsent();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const [isLoading, setIsLoading] = useState(true);
  const [isSending, setIsSending] = useState(false);
  const [error, setError] = useState('');
  const scrollRef = useRef<HTMLDivElement>(null);
  const loadedRef = useRef(false);
  const navigate = useNavigate();

  useEffect(() => {
    let current = true;
    loadedRef.current = false;
    getChat(itemType, itemId)
      .then((response) => { if (current) setMessages(response.messages || []); })
      .catch((err: unknown) => { if (current) setError(getErrorMessage(err)); })
      .finally(() => { if (current) setIsLoading(false); });
    return () => { current = false; };
  }, [itemId, itemType]);

  // Scroll the conversation box itself, never the page. The first load lands
  // on the latest message without animating.
  useLayoutEffect(() => {
    const box = scrollRef.current;
    if (!box || isLoading) return;
    box.scrollTo({ top: box.scrollHeight, behavior: loadedRef.current ? 'smooth' : 'auto' });
    loadedRef.current = true;
  }, [messages, isSending, isLoading]);

  const openCitation = (citation: Citation) => {
    if (onCitationClick) return onCitationClick(citation);
    const params = new URLSearchParams();
    if (typeof citation.start_ms === 'number') params.set('t', String(Math.floor(citation.start_ms / 1000)));
    if (typeof citation.page_number === 'number') params.set('page', String(citation.page_number));
    const search = params.toString();
    navigate(`${itemDetailPath(citation.item_type, citation.item_id)}${search ? `?${search}` : ''}`);
  };

  const send = async (event?: FormEvent) => {
    event?.preventDefault();
    const text = input.trim();
    if (!text || isSending) return;
    if (!(await requestConsent())) return;
    setIsSending(true);
    setError('');
    setInput('');
    try {
      const response = await sendChatMessage(itemType, itemId, text);
      setMessages((previous) => [...previous, ...response.messages]);
    } catch (err) {
      setError(getErrorMessage(err));
      setInput(text);
    } finally {
      setIsSending(false);
    }
  };

  return (
    <div className={`flex min-h-0 flex-col ${fill ? 'h-full' : ''}`}>
      <div ref={scrollRef} className={`min-h-0 overflow-y-auto overscroll-contain ${fill ? 'flex-1' : 'max-h-[min(60dvh,520px)]'}`} aria-live="polite">
        {isLoading ? (
          <p className="flex min-h-11 items-center gap-2 text-callout text-text-secondary" role="status"><Loader2 className="h-4 w-4 animate-spin" />Loading the conversation…</p>
        ) : messages.length === 0 ? (
          <p className="py-2 text-callout text-text-secondary">Ask anything about this. Answers cite where they came from.</p>
        ) : (
          <ol className="space-y-5 pb-2">
            {messages.map((message) => message.role === 'user' ? (
              <li key={message.id} className="flex justify-end">
                <p className="max-w-[85%] whitespace-pre-wrap rounded-lg bg-fill px-3.5 py-2.5 text-callout">{message.content}</p>
              </li>
            ) : (
              <li key={message.id}>
                <div className="text-[1.0625rem] leading-7 [&_a]:text-accent-text [&_a]:underline [&_code]:rounded-sm [&_code]:bg-fill [&_code]:px-1 [&_code]:font-mono [&_code]:text-[0.875em] [&_li]:mt-1 [&_ol]:list-decimal [&_ol]:pl-5 [&_p+p]:mt-3 [&_pre]:overflow-x-auto [&_pre]:rounded-md [&_pre]:bg-fill [&_pre]:p-3 [&_ul]:list-disc [&_ul]:pl-5 [&_strong]:font-semibold">
                  <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeSanitize]} components={{ a: ({ children, href }) => <a href={href} target="_blank" rel="noreferrer">{children}</a> }}>{message.content}</ReactMarkdown>
                </div>
                <CitationRow citations={message.citations} onClick={openCitation} />
                <AIContentReportButton targetType="chat_message" targetId={message.id} label="Report answer" />
              </li>
            ))}
            {isSending && <li className="flex items-center gap-2 text-callout text-text-secondary" role="status"><Loader2 className="h-4 w-4 animate-spin" />Thinking…</li>}
          </ol>
        )}
      </div>
      {error && <div className="mt-3"><Notice tone="error">{error}</Notice></div>}
      <form onSubmit={(event) => void send(event)} className="mt-3 flex items-end gap-2 rounded-[24px] bg-surface-2 py-0.5 pl-4 pr-0.5">
        <label className="sr-only" htmlFor={`ask-${itemType}-${itemId}`}>{placeholder}</label>
        <textarea
          id={`ask-${itemType}-${itemId}`}
          value={input}
          onChange={(event) => setInput(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault();
              void send();
            }
          }}
          placeholder={placeholder}
          rows={1}
          autoFocus={autoFocus}
          data-autofocus={autoFocus || undefined}
          className="max-h-40 min-h-[42px] flex-1 resize-none bg-transparent py-2.5 leading-6 text-text outline-none placeholder:text-text-secondary [field-sizing:content]"
        />
        <button type="submit" aria-label="Send" disabled={isSending || !input.trim()} className="pressable flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-accent-fill text-on-accent disabled:opacity-40">
          {isSending ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowUp className="h-[18px] w-[18px]" />}
        </button>
      </form>
    </div>
  );
}
