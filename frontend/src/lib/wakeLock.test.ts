import { describe, expect, it } from 'vitest';
import { createWakeLockKeeper, type WakeLockSentinelLike } from './wakeLock';

function fakeBrowser() {
  const sentinels: Array<WakeLockSentinelLike & { fireRelease: () => void }> = [];
  let requests = 0;
  const provider = {
    request: async () => {
      requests += 1;
      const listeners: Array<() => void> = [];
      const sentinel = {
        released: false,
        release: async () => { sentinel.released = true; },
        addEventListener: (_type: 'release', listener: () => void) => { listeners.push(listener); },
        // What the browser does when the tab is hidden.
        fireRelease: () => { sentinel.released = true; listeners.forEach((listener) => listener()); },
      };
      sentinels.push(sentinel);
      return sentinel;
    },
  };
  return { provider, sentinels, requests: () => requests };
}

describe('screen wake lock while recording', () => {
  it('asks again after the browser releases it in the background', async () => {
    const browser = fakeBrowser();
    const keeper = createWakeLockKeeper({ provider: () => browser.provider, wanted: () => true });
    await keeper.acquire();
    expect(keeper.held()).toBe(true);
    await keeper.acquire();
    expect(browser.requests()).toBe(1);

    browser.sentinels[0].fireRelease();
    expect(keeper.held()).toBe(false);

    await keeper.acquire();
    expect(browser.requests()).toBe(2);
    expect(keeper.held()).toBe(true);
  });

  it('treats a sentinel flagged released as gone even without the event', async () => {
    const browser = fakeBrowser();
    const keeper = createWakeLockKeeper({ provider: () => browser.provider, wanted: () => true });
    await keeper.acquire();
    browser.sentinels[0].released = true;
    await keeper.acquire();
    expect(browser.requests()).toBe(2);
  });

  it('does not ask while hidden or after recording ends, and never leaks a late lock', async () => {
    const browser = fakeBrowser();
    let wanted = false;
    const keeper = createWakeLockKeeper({ provider: () => browser.provider, wanted: () => wanted });
    await keeper.acquire();
    expect(browser.requests()).toBe(0);

    wanted = true;
    const pending = keeper.acquire();
    wanted = false; // recording stopped while the browser was deciding
    await pending;
    expect(keeper.held()).toBe(false);
    expect(browser.sentinels[0].released).toBe(true);
  });

  it('carries on when the browser refuses or has no wake lock', async () => {
    const refusing = createWakeLockKeeper({ provider: () => ({ request: async () => { throw new Error('denied'); } }), wanted: () => true });
    await expect(refusing.acquire()).resolves.toBeUndefined();
    expect(refusing.held()).toBe(false);
    const missing = createWakeLockKeeper({ provider: () => undefined, wanted: () => true });
    await expect(missing.acquire()).resolves.toBeUndefined();
  });

  it('releases the lock it holds', async () => {
    const browser = fakeBrowser();
    const keeper = createWakeLockKeeper({ provider: () => browser.provider, wanted: () => true });
    await keeper.acquire();
    keeper.release();
    expect(keeper.held()).toBe(false);
    expect(browser.sentinels[0].released).toBe(true);
  });
});
