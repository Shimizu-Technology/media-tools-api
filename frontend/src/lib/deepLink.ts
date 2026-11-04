import type { ItemDetailType } from './library';

/**
 * A citation from another item arrives as `?t=<seconds>` or `?page=<n>`. It
 * can only be followed once the thing it points at exists: the audio player,
 * the video, or the page's text. Following it too early would use up the link
 * and leave the person at the top of the item.
 */
export type DeepLink = { key: string; target: { seconds: number } | { page: number } | null };

export function parseDeepLink(params: URLSearchParams, type: ItemDetailType, itemId: string | undefined): DeepLink | null {
  const hasTime = params.has('t');
  const hasPage = params.has('page');
  if (!itemId || (!hasTime && !hasPage)) return null;
  // One key per item and place, so a second citation to another spot is never mistaken for the first.
  const key = `${type}:${itemId}:${hasTime ? `t=${params.get('t')}` : `page=${params.get('page')}`}`;
  if (hasTime) {
    const seconds = Number(params.get('t'));
    return { key, target: Number.isFinite(seconds) && seconds >= 0 ? { seconds } : null };
  }
  const page = Number(params.get('page'));
  return { key, target: Number.isFinite(page) && page > 0 ? { page: Math.floor(page) } : null };
}

export type DeepLinkContext = {
  type: ItemDetailType;
  /** The audio player is mounted. */
  audioPlayerReady: boolean;
  /** Fetching the playback address failed, so there will be no player. */
  audioUnavailable: boolean;
  /** The video can be embedded. */
  hasVideo: boolean;
  /** The text segments for this item have been fetched (successfully or not). */
  segmentsLoaded: boolean;
};

/** `wait` until the target exists, `go` to follow the link, `skip` when it cannot apply. */
export function deepLinkAction(link: DeepLink, context: DeepLinkContext): 'wait' | 'go' | 'skip' {
  const { target } = link;
  if (!target) return 'skip';
  if ('seconds' in target) {
    if (context.type === 'audio') return context.audioPlayerReady ? 'go' : context.audioUnavailable ? 'skip' : 'wait';
    if (context.type === 'transcript') return context.hasVideo ? 'go' : 'skip';
    return 'skip';
  }
  if (context.type !== 'pdf') return 'skip';
  return context.segmentsLoaded ? 'go' : 'wait';
}
