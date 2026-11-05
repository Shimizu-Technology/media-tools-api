import { Link } from 'react-router-dom';
import { AlertCircle, AudioLines, FileText, Link2, Loader2, MoreHorizontal, Star } from 'lucide-react';
import type { LibraryItem, LibraryItemCollection } from '../../lib/api';
import { collectionColorVar } from '../../lib/collections';
import { displayTitle, itemAttention, itemDetailPath, itemRowView } from '../../lib/library';
import { Waveform } from '../ui/Waveform';
import { Menu, type MenuItem } from '../ui/Menu';

const ROW_BARS = 16;

export function TypeIcon({ type, className = '' }: { type: LibraryItem['item_type']; className?: string }) {
  const Icon = type === 'audio' ? AudioLines : type === 'pdf' ? FileText : Link2;
  return <Icon className={className} aria-hidden="true" />;
}

/** The row's picture: real peaks when there are any, otherwise the type icon. */
export function ItemVisual({ item, peaks, processing }: { item: LibraryItem; peaks: number[] | null; processing: boolean }) {
  if (peaks) return <Waveform peaks={peaks} bars={ROW_BARS} progress={processing ? 0 : 1} className="h-10 w-16 shrink-0 md:w-24" />;
  return (
    <span className="flex h-10 w-16 shrink-0 items-center justify-center rounded-md bg-surface-2 text-accent-text md:w-24">
      <TypeIcon type={item.item_type} className="h-5 w-5" />
    </span>
  );
}

export function CollectionTag({ collection }: { collection: LibraryItemCollection }) {
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5">
      <span className="h-[7px] w-[7px] shrink-0 rounded-full" style={{ backgroundColor: collectionColorVar(collection.color) }} aria-hidden="true" />
      <span className="truncate">{collection.name}</span>
    </span>
  );
}

/** A status line for something moving or failed; null for a finished item. */
export function AttentionLabel({ item }: { item: LibraryItem }) {
  const attention = itemAttention(item);
  if (!attention) return null;
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5">
      {attention.kind === 'processing' ? <Loader2 className="h-3 w-3 shrink-0 animate-spin text-accent-text" aria-hidden="true" /> : <AlertCircle className="h-3 w-3 shrink-0 text-warning" aria-hidden="true" />}
      <span className={`truncate ${attention.kind === 'failed' ? 'text-text' : ''}`}>{attention.label}</span>
    </span>
  );
}

/**
 * One Library row: waveform or type icon, title and length, excerpt, then
 * collection and date. Lines with nothing to say are not drawn. `menu` is
 * desktop-only unless `alwaysShowMenu`: a phone reaches the same actions on the
 * item's own page.
 */
export function ItemRow({ item, menu, onRetry, from, alwaysShowMenu = false }: {
  item: LibraryItem;
  menu: MenuItem[];
  onRetry?: () => void;
  /** Where Back returns to, in words. */
  from?: string;
  alwaysShowMenu?: boolean;
}) {
  const view = itemRowView(item);
  const attention = itemAttention(item);
  const path = itemDetailPath(item.item_type, item.id);
  const details = [view.source, view.day].filter(Boolean);
  return (
    <li className="relative flex items-start gap-3 border-b border-separator py-3 last:border-b-0 md:gap-4">
      <ItemVisual item={item} peaks={view.waveform} processing={attention?.kind === 'processing'} />
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <Link
            to={path}
            state={from ? { from } : undefined}
            className="min-w-0 truncate text-row-title after:absolute after:inset-0 after:content-[''] focus-visible:outline-none [&:focus-visible]:after:rounded-sm [&:focus-visible]:after:outline-2 [&:focus-visible]:after:outline-accent-text"
          >
            {displayTitle(item.title)}
          </Link>
          {view.length && <span className="shrink-0 font-mono text-meta text-text-secondary">{view.length}</span>}
        </div>
        {view.excerpt && <p className="mt-0.5 line-clamp-2 text-excerpt text-text-secondary">{view.excerpt}</p>}
        <div className="mt-1 flex min-w-0 items-center gap-x-1.5 text-meta text-text-secondary">
          {item.favorite && <Star className="h-3 w-3 shrink-0 fill-current" aria-label="Starred" />}
          {attention ? <AttentionLabel item={item} /> : (
            <>
              {view.collection && <CollectionTag collection={view.collection} />}
              {view.collection && details.length > 0 && <span aria-hidden="true">·</span>}
              <span className="truncate">{details.join(' · ')}</span>
            </>
          )}
          {attention?.kind === 'failed' && onRetry && (
            <button type="button" onClick={onRetry} className="relative z-10 -my-3 inline-flex min-h-11 min-w-11 items-center justify-center px-1 font-semibold text-accent-text">Retry</button>
          )}
        </div>
      </div>
      {menu.length > 0 && (
        <div className={`relative z-10 -my-1 -mr-2 ${alwaysShowMenu ? '' : 'hidden md:block'}`}>
          <Menu label={`Actions for ${item.title}`} trigger={<MoreHorizontal className="h-5 w-5" />} triggerClassName="pressable inline-flex h-11 w-11 items-center justify-center rounded-full text-text-secondary hover:bg-fill" items={menu} />
        </div>
      )}
    </li>
  );
}

export function LoadingRows({ label }: { label: string }) {
  return (
    <div className="mt-2" role="status" aria-label={label}>
      {Array.from({ length: 6 }, (_, index) => (
        <div key={index} className="flex gap-3 border-b border-separator py-3 md:gap-4">
          <div className="h-10 w-16 shrink-0 rounded-md bg-fill md:w-24" />
          <div className="min-w-0 flex-1 space-y-2 py-1">
            <div className="h-4 rounded-sm bg-fill" style={{ width: `${70 - (index % 3) * 12}%` }} />
            <div className="h-3 w-24 rounded-sm bg-fill" />
          </div>
        </div>
      ))}
    </div>
  );
}
