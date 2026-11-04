/**
 * Light, dark, or follow the system. The choice lives in localStorage under
 * `mta_theme` ('light' | 'dark'); no value means follow the system.
 */
export type ThemePreference = 'system' | 'light' | 'dark';

const STORAGE_KEY = 'mta_theme';
const CHANGED_EVENT = 'media-tools:theme-changed';
// Matches --color-bg in index.css, so the browser chrome blends with the page.
const BAR_COLORS = { light: '#f7f5f0', dark: '#191714' } as const;

export function parseThemePreference(value: string | null): ThemePreference {
  return value === 'light' || value === 'dark' ? value : 'system';
}

export function getThemePreference(): ThemePreference {
  try {
    return parseThemePreference(localStorage.getItem(STORAGE_KEY));
  } catch {
    return 'system';
  }
}

export function resolveTheme(preference: ThemePreference, systemDark: boolean): 'light' | 'dark' {
  if (preference === 'system') return systemDark ? 'dark' : 'light';
  return preference;
}

function systemPrefersDark(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia('(prefers-color-scheme: dark)').matches;
}

export function applyTheme(preference: ThemePreference = getThemePreference()): 'light' | 'dark' {
  const resolved = resolveTheme(preference, systemPrefersDark());
  document.documentElement.classList.toggle('dark', resolved === 'dark');
  // A manual choice must win over the media-specific theme-color tags too.
  document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]').forEach((meta) => {
    meta.content = BAR_COLORS[resolved];
  });
  return resolved;
}

export function setThemePreference(preference: ThemePreference): void {
  try {
    if (preference === 'system') localStorage.removeItem(STORAGE_KEY);
    else localStorage.setItem(STORAGE_KEY, preference);
  } catch {
    // Storage can be blocked; the choice still applies to this page.
  }
  applyTheme(preference);
  window.dispatchEvent(new Event(CHANGED_EVENT));
}

export function subscribeTheme(listener: () => void): () => void {
  window.addEventListener(CHANGED_EVENT, listener);
  return () => window.removeEventListener(CHANGED_EVENT, listener);
}

/** Apply the stored choice now and follow the system while no choice is stored. */
export function startThemeSync(): void {
  applyTheme();
  if (typeof window.matchMedia !== 'function') return;
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (getThemePreference() === 'system') applyTheme('system');
  });
  // Another tab changed the choice.
  window.addEventListener('storage', (event) => {
    if (event.key === STORAGE_KEY) {
      applyTheme();
      window.dispatchEvent(new Event(CHANGED_EVENT));
    }
  });
}
