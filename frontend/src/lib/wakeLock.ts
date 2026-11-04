/**
 * Keeps the screen awake while something needs it, and takes the lock back when
 * the browser drops it. Browsers release a screen wake lock whenever the tab is
 * hidden, so a lock held across a trip to another app is gone on return: the
 * sentinel's `release` event clears our hold, and the next `acquire()` asks
 * again.
 */
export type WakeLockSentinelLike = {
  released?: boolean;
  release: () => Promise<void>;
  addEventListener?: (type: 'release', listener: () => void) => void;
};

export type WakeLockProvider = { request: (type: 'screen') => Promise<WakeLockSentinelLike> };

export function createWakeLockKeeper(options: {
  provider: () => WakeLockProvider | undefined;
  /** False when a lock would be pointless or refused (tab hidden, recording over). */
  wanted: () => boolean;
}) {
  let sentinel: WakeLockSentinelLike | null = null;
  let pending = false;

  const held = () => sentinel !== null && sentinel.released !== true;

  return {
    held,
    async acquire() {
      if (held() || pending || !options.wanted()) return;
      const provider = options.provider();
      if (!provider) return;
      pending = true;
      try {
        const next = await provider.request('screen');
        // Recording ended while the browser was deciding: do not leak the lock.
        if (!options.wanted()) {
          void next.release().catch(() => undefined);
          return;
        }
        sentinel = next;
        next.addEventListener?.('release', () => { if (sentinel === next) sentinel = null; });
      } catch {
        // Not allowed here (battery saver, permissions policy); recording continues.
      } finally {
        pending = false;
      }
    },
    release() {
      const current = sentinel;
      sentinel = null;
      void current?.release().catch(() => undefined);
    },
  };
}
