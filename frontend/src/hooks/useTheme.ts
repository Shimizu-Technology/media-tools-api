import { useSyncExternalStore } from 'react';
import { getThemePreference, setThemePreference, subscribeTheme, type ThemePreference } from '../lib/theme';

/** The stored appearance choice: system, light, or dark. */
export function useTheme() {
  const preference = useSyncExternalStore(subscribeTheme, getThemePreference, () => 'system' as ThemePreference);
  return { preference, setPreference: setThemePreference };
}
