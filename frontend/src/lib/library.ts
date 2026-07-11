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
