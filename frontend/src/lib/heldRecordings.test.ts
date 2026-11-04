import { describe, expect, it } from 'vitest';
import { hasUnsavedRecording, holdRecording, releaseRecording, type HeldRecording } from './heldRecordings';

const entry = (id: string, savedOnDevice: boolean, warning = ''): HeldRecording => ({
  recording: { id, blob: new Blob(['audio']), mimeType: 'audio/webm', durationSeconds: 5, createdAt: 1 },
  warning,
  savedOnDevice,
});

describe('recordings kept in memory', () => {
  it('keeps a recording through a failed save until it is uploaded or deleted', () => {
    let list = holdRecording([], entry('a', false));
    expect(hasUnsavedRecording(list)).toBe(true);
    // A failed upload holds the same recording again: still one copy, still unsaved.
    list = holdRecording(list, entry('a', false));
    expect(list).toHaveLength(1);
    expect(hasUnsavedRecording(list)).toBe(true);
    list = releaseRecording(list, 'a');
    expect(list).toEqual([]);
    expect(hasUnsavedRecording(list)).toBe(false);
  });

  it('never drops an earlier unsaved recording when a new one is held', () => {
    const list = holdRecording(holdRecording([], entry('a', false)), entry('b', true));
    expect(list.map((held) => held.recording.id)).toEqual(['b', 'a']);
    expect(hasUnsavedRecording(list)).toBe(true);
    expect(hasUnsavedRecording(releaseRecording(list, 'a'))).toBe(false);
  });
});
