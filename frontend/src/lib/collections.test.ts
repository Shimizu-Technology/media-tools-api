import { describe, expect, it } from 'vitest';
import { collectionColor, collectionColorVar, isCollectionId } from './collections';

describe('collection colors', () => {
  it.each(['coral', 'teal', 'violet', 'amber', 'blue', 'rose'])('keeps %s', (key) => {
    expect(collectionColor(key)).toBe(key);
  });

  it.each([[undefined], [null], [''], ['lime'], ['#D9542E'], ['constructor']])('falls back to coral for %j', (key) => {
    expect(collectionColor(key)).toBe('coral');
    expect(collectionColorVar(key)).toBe('var(--color-collection-coral)');
  });
});

describe('collection ids', () => {
  it('accepts server ids and refuses anything that could change the path', () => {
    expect(isCollectionId('0d1f1f2a-7c4e-4a51-9a8c-2b6b1b2c3d4e')).toBe(true);
    expect(isCollectionId('../settings')).toBe(false);
    expect(isCollectionId('')).toBe(false);
    expect(isCollectionId(undefined)).toBe(false);
  });
});
