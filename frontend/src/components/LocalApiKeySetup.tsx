import { lazy, Suspense } from 'react';
import { localApiKeyMode } from '../lib/webSession';

// `localApiKeyMode` is a build-time constant, so a production build keeps none
// of the API-key setup UI.
const ApiKeySetup = localApiKeyMode ? lazy(() => import('./ApiKeySetup').then((m) => ({ default: m.ApiKeySetup }))) : null;

/** The development API-key form, or nothing in a production build. */
export function LocalApiKeySetup({ onKeySet, hasKey }: { onKeySet: (key: string) => void; hasKey: boolean }) {
  if (!ApiKeySetup) return null;
  return <Suspense fallback={null}><ApiKeySetup onKeySet={onKeySet} hasKey={hasKey} /></Suspense>;
}
