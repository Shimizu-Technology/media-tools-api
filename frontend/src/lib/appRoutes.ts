/**
 * Every place the app used to live, and where it lives now. Old bookmarks,
 * Home Screen shortcuts, shared links, and the native apps' deep links keep
 * working through these redirects.
 *
 * The signed-in app: Home, Library, Collections and a collection, Add, an item,
 * and Settings with its Developer, Webhooks and Ops pages. `/app` was the Library
 * until Home took its place, so `/app` with a query is still a Library link.
 */
export const APP_ROUTES = {
  home: '/app',
  library: '/app/library',
  collections: '/app/collections',
  add: '/app/new',
  settings: '/app/settings',
  developer: '/app/settings/developer',
  webhooks: '/app/settings/webhooks',
  ops: '/app/settings/ops',
} as const;

export function collectionPath(id: string): string {
  return `${APP_ROUTES.collections}/${id}`;
}

/** Paths that only redirect. The router mounts one redirect route for each. */
export const LEGACY_PATHS = [
  '/audio',
  '/pdf',
  '/library',
  '/collections',
  '/collections/:collectionId',
  '/history',
  '/webhooks',
  '/ops',
  '/app/video',
  '/app/audio',
  '/app/pdf',
  '/app/processing',
  '/app/developer',
  '/app/developer/webhooks',
  '/app/admin/ops',
] as const;

const ITEM_ID = /^[A-Za-z0-9-]{1,64}$/;

function itemPath(type: 'transcript' | 'audio' | 'pdf', id: string | null): string | null {
  if (!id || !ITEM_ID.test(id)) return null;
  return `/app/items/${type}/${id}`;
}

function withQuery(path: string, params: URLSearchParams): string {
  const query = params.toString();
  return query ? `${path}?${query}` : path;
}

/** The old library and activity filters, rewritten to the Library's names. */
function libraryParams(search: URLSearchParams, defaults: Record<string, string> = {}): URLSearchParams {
  const next = new URLSearchParams();
  for (const [key, value] of Object.entries(defaults)) next.set(key, value);
  const type = search.get('type');
  if (type === 'youtube' || type === 'audio' || type === 'pdf') next.set('type', type);
  const status = search.get('status');
  if (status === 'failed' || status === 'completed' || status === 'active') next.set('status', status);
  if (status === 'processing' || status === 'pending') next.set('status', 'active');
  const view = search.get('view');
  if (view === 'favorites' || view === 'archive') next.set('view', view);
  const query = search.get('q') || search.get('search');
  if (query) next.set('q', query);
  return next;
}

function collectionTarget(collectionId: string | undefined, query = new URLSearchParams()): string {
  return collectionId && ITEM_ID.test(collectionId) ? withQuery(collectionPath(collectionId), query) : APP_ROUTES.collections;
}

/**
 * `/app` is Home. With a query it is an old Library link, which keeps every
 * parameter; `collection` became a page of its own.
 */
function appLinkRedirect(params: URLSearchParams): string | null {
  if ([...params.keys()].length === 0) return null;
  const rest = new URLSearchParams(params);
  const collection = rest.get('collection');
  if (collection === null) return withQuery(APP_ROUTES.library, rest);
  rest.delete('collection');
  return collection ? collectionTarget(collection, rest) : withQuery(APP_ROUTES.library, rest);
}

/**
 * Where an old URL goes now, or null when the URL is current. Pure, so the
 * whole table is unit-tested.
 */
export function legacyRedirect(pathname: string, search: string): string | null {
  const path = pathname.length > 1 ? pathname.replace(/\/+$/, '') : pathname;
  const params = new URLSearchParams(search);
  const id = params.get('id');

  if (path === '/') {
    const shared = itemPath('transcript', params.get('id') || params.get('transcript'));
    return shared;
  }

  if (path === APP_ROUTES.home) return appLinkRedirect(params);

  const collection = path.match(/^\/collections\/([^/]+)$/);
  if (collection) return collectionTarget(decodeURIComponent(collection[1]), params);

  switch (path) {
    case '/app/video':
      return itemPath('transcript', id || params.get('transcript')) ?? withQuery(APP_ROUTES.add, new URLSearchParams({ source: 'link' }));
    case '/audio':
    case '/app/audio':
      return itemPath('audio', id) ?? APP_ROUTES.add;
    case '/pdf':
    case '/app/pdf':
      return itemPath('pdf', id) ?? withQuery(APP_ROUTES.add, new URLSearchParams({ source: 'file' }));
    case '/library':
      return withQuery(APP_ROUTES.library, libraryParams(params));
    case '/history':
      return withQuery(APP_ROUTES.library, libraryParams(params, { type: 'youtube' }));
    case '/app/processing': {
      const next = libraryParams(params);
      if (!next.has('status')) next.set('status', 'active');
      return withQuery(APP_ROUTES.library, next);
    }
    case '/collections':
      return APP_ROUTES.collections;
    case '/app/developer':
      return APP_ROUTES.developer;
    case '/webhooks':
    case '/app/developer/webhooks':
      return APP_ROUTES.webhooks;
    case '/ops':
    case '/app/admin/ops':
      return APP_ROUTES.ops;
    default:
      return null;
  }
}
