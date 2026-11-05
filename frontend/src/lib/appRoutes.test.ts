import { describe, expect, it } from 'vitest';
import { LEGACY_PATHS, legacyRedirect } from './appRoutes';

const ID = '0d1f1f2a-7c4e-4a51-9a8c-2b6b1b2c3d4e';

describe('legacy redirects', () => {
  it.each([
    ['/app/video', '', '/app/new?source=link'],
    ['/app/video', `?id=${ID}`, `/app/items/transcript/${ID}`],
    ['/app/video', `?transcript=${ID}`, `/app/items/transcript/${ID}`],
    ['/app/audio', '', '/app/new'],
    ['/app/audio', `?id=${ID}`, `/app/items/audio/${ID}`],
    ['/audio', `?id=${ID}`, `/app/items/audio/${ID}`],
    ['/app/pdf', '', '/app/new?source=file'],
    ['/pdf', `?id=${ID}`, `/app/items/pdf/${ID}`],
    ['/library', '', '/app/library'],
    ['/library', '?type=audio', '/app/library?type=audio'],
    ['/library', '?type=pdf&status=failed&view=archive', '/app/library?type=pdf&status=failed&view=archive'],
    ['/library', '?status=processing', '/app/library?status=active'],
    ['/library', '?type=spreadsheet&status=everything', '/app/library'],
    ['/history', '', '/app/library?type=youtube'],
    ['/app/processing', '', '/app/library?status=active'],
    ['/app/processing', '?status=failed', '/app/library?status=failed'],
    ['/app/processing', '?status=completed', '/app/library?status=completed'],
    ['/collections', '', '/app/collections'],
    ['/collections/abc-123', '', '/app/collections/abc-123'],
    ['/collections/abc-123', '?q=budget&type=audio', '/app/collections/abc-123?q=budget&type=audio'],
    ['/app/developer', '', '/app/settings/developer'],
    ['/app/developer/webhooks', '', '/app/settings/webhooks'],
    ['/webhooks', '', '/app/settings/webhooks'],
    ['/app/admin/ops', '', '/app/settings/ops'],
    ['/ops', '', '/app/settings/ops'],
    ['/library/', '', '/app/library'],
  ])('%s%s goes to %s', (path, search, target) => {
    expect(legacyRedirect(path, search)).toBe(target);
  });

  // /app was the Library, and these links are in bookmarks and old messages.
  it.each([
    ['?status=active', '/app/library?status=active'],
    ['?status=failed', '/app/library?status=failed'],
    ['?type=audio&view=favorites', '/app/library?type=audio&view=favorites'],
    ['?q=lease+renewal&page=3&sort=asc', '/app/library?q=lease+renewal&page=3&sort=asc'],
    ['?collection=abc-123', '/app/collections/abc-123'],
    ['?collection=abc-123&q=baby&type=audio', '/app/collections/abc-123?q=baby&type=audio'],
    ['?collection=&type=pdf', '/app/library?type=pdf'],
    ['?collection=..%2Fsettings', '/app/collections'],
  ])('/app%s keeps working at %s', (search, target) => {
    expect(legacyRedirect('/app', search)).toBe(target);
    expect(legacyRedirect('/app/', search)).toBe(target);
  });

  it('leaves /app alone with no query: it is Home now', () => {
    expect(legacyRedirect('/app', '')).toBeNull();
    expect(legacyRedirect('/app/', '')).toBeNull();
  });

  it('sends a shared transcript link on the landing page to the item', () => {
    expect(legacyRedirect('/', `?id=${ID}`)).toBe(`/app/items/transcript/${ID}`);
    expect(legacyRedirect('/', `?transcript=${ID}`)).toBe(`/app/items/transcript/${ID}`);
    expect(legacyRedirect('/', '')).toBeNull();
  });

  it('never builds a path from an unsafe id', () => {
    expect(legacyRedirect('/app/audio', '?id=../../settings')).toBe('/app/new');
    expect(legacyRedirect('/app/video', '?id=%2F%2Fevil.example')).toBe('/app/new?source=link');
    expect(legacyRedirect('/collections/..%2Fsettings', '')).toBe('/app/collections');
  });

  it('leaves current routes alone', () => {
    for (const path of ['/app', '/app/library', '/app/collections', '/app/collections/abc-123', '/app/new', '/app/settings', '/app/settings/developer', `/app/items/audio/${ID}`, '/sign-in', '/privacy']) {
      expect(legacyRedirect(path, '')).toBeNull();
    }
  });

  it('has a redirect for every legacy path the router mounts', () => {
    for (const path of LEGACY_PATHS) {
      const concrete = path.replace(':collectionId', 'abc');
      expect(legacyRedirect(concrete, ''), path).not.toBeNull();
    }
  });
});
