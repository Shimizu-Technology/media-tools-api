import { describe, expect, it } from 'vitest';
import { activityItemLabel, describeActivity, isScopedKey, scopeLabel, SCOPE_PRESETS, toggleScope } from './agentAccess';

describe('scoped key helpers', () => {
  it('treats only keys with scopes as agent keys', () => {
    expect(isScopedKey({ scopes: ['library:read'] })).toBe(true);
    expect(isScopedKey({ scopes: [] })).toBe(false);
    expect(isScopedKey({})).toBe(false);
  });

  it('toggles scopes while keeping canonical order', () => {
    expect(toggleScope(['library:write'], 'library:read')).toEqual(['library:read', 'library:write']);
    expect(toggleScope(['library:read', 'library:write'], 'library:read')).toEqual(['library:write']);
    expect(toggleScope([], 'capture:upload')).toEqual(['capture:upload']);
  });

  it('labels known scopes and passes unknown ones through', () => {
    expect(scopeLabel('library:delete')).toBe('Delete');
    expect(scopeLabel('future:scope')).toBe('future:scope');
  });

  it('offers an upload-only preset that cannot read', () => {
    const upload = SCOPE_PRESETS.find((preset) => preset.id === 'upload');
    expect(upload?.scopes).toEqual(['capture:upload']);
  });
});

describe('agent activity text', () => {
  it('describes a rename and a refused delete', () => {
    expect(describeActivity({ method: 'PATCH', route: '/api/v1/audio/transcriptions/:id', status_code: 200 })).toBe('Renamed a recording');
    expect(describeActivity({ method: 'DELETE', route: '/api/v1/audio/transcriptions/:id', status_code: 403 })).toBe('Blocked: deleted a recording');
  });

  it('falls back to the method and route for unknown actions', () => {
    expect(describeActivity({ method: 'POST', route: '/api/v1/keys', status_code: 403 })).toBe('Blocked: POST /keys');
    expect(describeActivity({ method: 'POST', route: '/api/v1/collections/:id/items', status_code: 500 })).toBe('Failed: filed items in a collection');
  });

  it('shortens item ids', () => {
    expect(activityItemLabel({ item_type: 'audio', item_id: '12345678-aaaa-bbbb-cccc-1234567890ab' })).toBe('audio 12345678');
    expect(activityItemLabel({ item_type: '', item_id: '' })).toBe('');
  });
});
