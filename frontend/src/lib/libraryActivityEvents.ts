export const LIBRARY_ACTIVITY_CHANGED_EVENT = 'media-tools:library-activity-changed';

/**
 * Notify the app shell that a successful mutation may have changed the active
 * job list. Keeping this event local to the browser avoids idle server polling
 * while still refreshing the global processing badge immediately.
 */
export function notifyLibraryActivityChanged(): void {
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new Event(LIBRARY_ACTIVITY_CHANGED_EVENT));
  }
}
