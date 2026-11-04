/**
 * Collection colors are stored by name. An unknown or missing key, which is what
 * every collection has until the server adds the field, falls back to coral.
 */
export const COLLECTION_COLORS = ['coral', 'teal', 'violet', 'amber', 'blue', 'rose'] as const;
export type CollectionColor = (typeof COLLECTION_COLORS)[number];

export function collectionColor(key?: string | null): CollectionColor {
  return COLLECTION_COLORS.includes(key as CollectionColor) ? (key as CollectionColor) : 'coral';
}

export function collectionColorVar(key?: string | null): string {
  return `var(--color-collection-${collectionColor(key)})`;
}

const COLLECTION_ID = /^[A-Za-z0-9-]{1,64}$/;

export function isCollectionId(value: string | null | undefined): value is string {
  return typeof value === 'string' && COLLECTION_ID.test(value);
}
