import type { PendingRecording } from './recordingStore';

/**
 * A finished recording kept in memory until it is uploaded or deleted on
 * purpose. It outlives a failed save to this device, a declined consent
 * prompt, and a failed upload, so the audio can always be played, downloaded
 * or retried from the page.
 */
export type HeldRecording = { recording: PendingRecording; warning: string; savedOnDevice: boolean };

export function holdRecording(list: HeldRecording[], entry: HeldRecording): HeldRecording[] {
  return [entry, ...list.filter((other) => other.recording.id !== entry.recording.id)];
}

export function releaseRecording(list: HeldRecording[], id: string): HeldRecording[] {
  return list.filter((entry) => entry.recording.id !== id);
}

/** True when some recording exists only in this page's memory: leaving would lose it. */
export function hasUnsavedRecording(list: HeldRecording[]): boolean {
  return list.some((entry) => !entry.savedOnDevice);
}
