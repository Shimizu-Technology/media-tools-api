import type { LibraryItem } from './api';

export type ItemDetailType = 'transcript' | 'audio' | 'pdf';

export function normalizeItemType(itemType: LibraryItem['item_type'] | ItemDetailType): ItemDetailType {
  return itemType === 'youtube' ? 'transcript' : itemType;
}

export function itemDetailPath(itemType: LibraryItem['item_type'] | ItemDetailType, itemId: string): string {
  return `/app/items/${normalizeItemType(itemType)}/${itemId}`;
}

export function itemTypeLabel(itemType: LibraryItem['item_type'] | ItemDetailType): 'Video' | 'Recording' | 'PDF' {
  switch (normalizeItemType(itemType)) {
    case 'transcript': return 'Video';
    case 'audio': return 'Recording';
    case 'pdf': return 'PDF';
  }
}

/**
 * Status only shows when something needs attention or is still moving. A
 * finished item shows nothing at all.
 */
export function itemAttention(item: Pick<LibraryItem, 'item_type' | 'status' | 'summary_status' | 'word_count'>): { kind: 'processing' | 'failed'; label: string } | null {
  if (item.status === 'failed') return { kind: 'failed', label: item.item_type === 'audio' ? 'Transcription failed' : item.item_type === 'pdf' ? 'Could not read this PDF' : 'Could not get the transcript' };
  if (item.status !== 'pending' && item.status !== 'processing') return null;
  const summarizing = item.summary_status === 'pending' || item.summary_status === 'processing';
  if (summarizing && item.word_count > 0) return { kind: 'processing', label: 'Writing summary' };
  if (item.item_type === 'pdf') return { kind: 'processing', label: 'Reading PDF' };
  if (item.item_type === 'youtube') return { kind: 'processing', label: 'Getting transcript' };
  return { kind: 'processing', label: item.status === 'pending' ? 'Waiting to transcribe' : 'Transcribing' };
}

const MEDIA_EXTENSION = /\.(m4a|mp3|wav|caf|aac|ogg|flac|webm|mp4|mov|qta)$/i;

/** A title as people read it: "Planning call", not "Planning call.m4a". Display only. */
export function displayTitle(title: string): string {
  const trimmed = title.trim();
  return trimmed.replace(MEDIA_EXTENSION, '') || trimmed;
}
