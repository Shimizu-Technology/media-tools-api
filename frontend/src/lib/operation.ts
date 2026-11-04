/**
 * One cancellable operation at a time (an upload, say). Starting another or
 * calling `cancel()` aborts the request and flips `live()` to false, so work
 * queued behind the request (state updates, navigation) can check it and stop.
 */
export function createOperationSlot() {
  let current: AbortController | null = null;
  return {
    begin() {
      current?.abort();
      const controller = new AbortController();
      current = controller;
      return { signal: controller.signal, live: () => !controller.signal.aborted };
    },
    cancel() {
      current?.abort();
      current = null;
    },
  };
}
