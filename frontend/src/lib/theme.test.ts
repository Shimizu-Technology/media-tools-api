import { describe, expect, it } from 'vitest';
import { parseThemePreference, resolveTheme } from './theme';

describe('theme preference', () => {
  it('treats anything but light or dark as following the system', () => {
    expect(parseThemePreference('light')).toBe('light');
    expect(parseThemePreference('dark')).toBe('dark');
    expect(parseThemePreference(null)).toBe('system');
    expect(parseThemePreference('sepia')).toBe('system');
  });

  it('resolves system against the device setting and keeps a manual choice', () => {
    expect(resolveTheme('system', true)).toBe('dark');
    expect(resolveTheme('system', false)).toBe('light');
    expect(resolveTheme('light', true)).toBe('light');
    expect(resolveTheme('dark', false)).toBe('dark');
  });
});
