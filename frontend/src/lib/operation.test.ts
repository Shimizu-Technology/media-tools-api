import { describe, expect, it } from 'vitest';
import { createOperationSlot } from './operation';

describe('cancellable operation', () => {
  it('is live until cancelled, and cancelling aborts the request', () => {
    const slot = createOperationSlot();
    const operation = slot.begin();
    expect(operation.live()).toBe(true);
    slot.cancel();
    expect(operation.live()).toBe(false);
    expect(operation.signal.aborted).toBe(true);
  });

  it('retires the previous operation when another begins', () => {
    const slot = createOperationSlot();
    const first = slot.begin();
    const second = slot.begin();
    expect(first.live()).toBe(false);
    expect(second.live()).toBe(true);
  });

  it('cancelling with nothing running is harmless', () => {
    expect(() => createOperationSlot().cancel()).not.toThrow();
  });
});
