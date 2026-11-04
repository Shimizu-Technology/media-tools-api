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
    ['/app/library', '', '/app'],
    ['/library', '?type=audio', '/app?type=audio'],
    ['/app/library', '?type=pdf&status=failed&view=archive', '/app?type=pdf&status=failed&view=archive'],
    ['/app/library', '?status=processing', '/app?status=active'],
    ['/app/library', '?type=spreadsheet&status=everything', '/app'],
    ['/history', '', '/app?type=youtube'],
    ['/app/processing', '', '/app?status=active'],
    ['/app/processing', '?status=failed', '/app?status=failed'],
    ['/app/processing', '?status=completed', '/app?status=completed'],
    ['/app/collections', '', '/app'],
    ['/collections', '', '/app'],
    ['/app/collections/abc-123', '', '/app?collection=abc-123'],
    ['/collections/abc-123', '', '/app?collection=abc-123'],
    ['/app/developer', '', '/app/settings/developer'],
    ['/app/developer/webhooks', '', '/app/settings/webhooks'],
    ['/webhooks', '', '/app/settings/webhooks'],
    ['/app/admin/ops', '', '/app/settings/ops'],
    ['/ops', '', '/app/settings/ops'],
    ['/app/library/', '', '/app'],
  ])('%s%s goes to %s', (path, search, target) => {
    expect(legacyRedirect(path, search)).toBe(target);
  });

  it('sends a shared transcript link on the landing page to the item', () => {
    expect(legacyRedirect('/', `?id=${ID}`)).toBe(`/app/items/transcript/${ID}`);
    expect(legacyRedirect('/', `?transcript=${ID}`)).toBe(`/app/items/transcript/${ID}`);
    expect(legacyRedirect('/', '')).toBeNull();
  });

  it('never builds a path from an unsafe id', () => {
    expect(legacyRedirect('/app/audio', '?id=../../settings')).toBe('/app/new');
    expect(legacyRedirect('/app/video', '?id=%2F%2Fevil.example')).toBe('/app/new?source=link');
    expect(legacyRedirect('/app/collections/..%2Fsettings', '')).toBe('/app');
  });

  it('leaves current routes alone', () => {
    for (const path of ['/app', '/app/new', '/app/settings', '/app/settings/developer', `/app/items/audio/${ID}`, '/sign-in', '/privacy']) {
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
