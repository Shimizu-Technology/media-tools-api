import { describe, expect, it } from 'vitest';
import { deepLinkAction, parseDeepLink, type DeepLinkContext } from './deepLink';

const context = (overrides: Partial<DeepLinkContext> = {}): DeepLinkContext => ({
  type: 'audio', audioPlayerReady: false, audioUnavailable: false, hasVideo: false, segmentsLoaded: false, ...overrides,
});

describe('following a citation into another item', () => {
  it('keys a link by item and place, so a second citation is its own link', () => {
    const first = parseDeepLink(new URLSearchParams('t=30'), 'audio', 'a1');
    const second = parseDeepLink(new URLSearchParams('t=95'), 'audio', 'a1');
    const otherItem = parseDeepLink(new URLSearchParams('t=30'), 'audio', 'a2');
    expect(new Set([first?.key, second?.key, otherItem?.key]).size).toBe(3);
  });

  it('reads a time or a page, and ignores nonsense', () => {
    expect(parseDeepLink(new URLSearchParams('t=12.5'), 'audio', 'a')?.target).toEqual({ seconds: 12.5 });
    expect(parseDeepLink(new URLSearchParams('page=4'), 'pdf', 'p')?.target).toEqual({ page: 4 });
    expect(parseDeepLink(new URLSearchParams('t=abc'), 'audio', 'a')?.target).toBeNull();
    expect(parseDeepLink(new URLSearchParams('page=0'), 'pdf', 'p')?.target).toBeNull();
    expect(parseDeepLink(new URLSearchParams(''), 'audio', 'a')).toBeNull();
  });

  it('waits for the audio player instead of using the link up', () => {
    const link = parseDeepLink(new URLSearchParams('t=30'), 'audio', 'a1')!;
    expect(deepLinkAction(link, context())).toBe('wait');
    expect(deepLinkAction(link, context({ audioPlayerReady: true }))).toBe('go');
    expect(deepLinkAction(link, context({ audioUnavailable: true }))).toBe('skip');
  });

  it('waits for the page text of a PDF', () => {
    const link = parseDeepLink(new URLSearchParams('page=3'), 'pdf', 'p1')!;
    expect(deepLinkAction(link, context({ type: 'pdf' }))).toBe('wait');
    expect(deepLinkAction(link, context({ type: 'pdf', segmentsLoaded: true }))).toBe('go');
  });

  it('follows a video time only when there is a video, and drops links that do not fit the item', () => {
    const time = parseDeepLink(new URLSearchParams('t=60'), 'transcript', 't1')!;
    expect(deepLinkAction(time, context({ type: 'transcript', hasVideo: true }))).toBe('go');
    expect(deepLinkAction(time, context({ type: 'transcript' }))).toBe('skip');
    expect(deepLinkAction(time, context({ type: 'pdf' }))).toBe('skip');
    const page = parseDeepLink(new URLSearchParams('page=2'), 'audio', 'a1')!;
    expect(deepLinkAction(page, context())).toBe('skip');
  });
});
