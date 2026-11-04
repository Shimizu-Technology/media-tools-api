import { describe, expect, it } from 'vitest';
import { safeNextPath } from './authRedirect';

describe('sign-in destinations', () => {
  it('keeps same-origin app paths', () => {
    expect(safeNextPath('/app/settings')).toBe('/app/settings');
    expect(safeNextPath('/app/library?type=pdf')).toBe('/app/library?type=pdf');
  });

  it.each([null, '', 'https://evil.example', '//evil.example', '/\\evil.example', 'javascript:alert(1)', 'app'])('falls back for %s', (value) => {
    expect(safeNextPath(value)).toBe('/app');
  });

  it('does not loop back into the sign-in screens', () => {
    expect(safeNextPath('/sign-in?next=/app')).toBe('/app');
    expect(safeNextPath('/forgot-password')).toBe('/app');
  });
});
