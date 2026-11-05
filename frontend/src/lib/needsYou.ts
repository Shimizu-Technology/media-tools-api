import type { LibraryItem } from './api';
import type { PendingRecording } from './recordingStore';

const WINDOW_DAYS = 7;
const DAY_MS = 86_400_000;

export type NeedsYouEntry =
  | { kind: 'recording'; key: string; recording: PendingRecording }
  | { kind: 'failed'; key: string; item: LibraryItem };

function failedAt(item: LibraryItem): number {
  return new Date(item.created_at).getTime();
}

/** Failed in the last week and not archived. Older failures stay in the Library. */
export function isRecentFailure(item: LibraryItem, now: number): boolean {
  if (item.status !== 'failed' || item.archived) return false;
  const at = failedAt(item);
  return !Number.isNaN(at) && now - at <= WINDOW_DAYS * DAY_MS;
}

/**
 * What Home asks the person to do: recordings still only in this browser, then
 * recent server failures, newest first. Empty means the section disappears.
 */
export function selectNeedsYou(failed: LibraryItem[], recordings: PendingRecording[], now = Date.now()): NeedsYouEntry[] {
  const onDevice = [...recordings]
    .sort((a, b) => b.createdAt - a.createdAt)
    .map((recording): NeedsYouEntry => ({ kind: 'recording', key: `recording-${recording.id}`, recording }));
  const failures = failed
    .filter((item) => isRecentFailure(item, now))
    .sort((a, b) => failedAt(b) - failedAt(a))
    .map((item): NeedsYouEntry => ({ kind: 'failed', key: `${item.item_type}-${item.id}`, item }));
  return [...onDevice, ...failures];
}

/**
 * Browser recordings exist nowhere else, so Home never hides them. Only server
 * failures, which the Library's failed filter also lists, are cut to fit.
 */
export function limitNeedsYou(entries: NeedsYouEntry[], limit: number): { shown: NeedsYouEntry[]; hiddenFailures: number } {
  const onDevice = entries.filter((entry) => entry.kind === 'recording');
  const failures = entries.filter((entry) => entry.kind === 'failed');
  const room = Math.max(0, limit - onDevice.length);
  return { shown: [...onDevice, ...failures.slice(0, room)], hiddenFailures: Math.max(0, failures.length - room) };
}

/** Good morning until noon, good afternoon until five, then good evening. */
export function greeting(hour: number): string {
  if (hour >= 5 && hour < 12) return 'Good morning';
  if (hour >= 12 && hour < 17) return 'Good afternoon';
  return 'Good evening';
}
