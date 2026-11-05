import { describe, expect, it } from 'vitest';
import { classifyFile, looksLikeURL, recordingFileName } from './mediaUpload';

describe('adding files', () => {
  it('sends audio and video to transcription and PDFs to extraction', () => {
    expect(classifyFile({ name: 'Memo.M4A', size: 1000 })).toEqual({ kind: 'audio' });
    expect(classifyFile({ name: 'zoom.mov', size: 1000 })).toEqual({ kind: 'audio' });
    expect(classifyFile({ name: 'contract.pdf', size: 1000 })).toEqual({ kind: 'pdf' });
  });

  it('explains what it cannot take', () => {
    expect(classifyFile({ name: 'notes.docx', size: 10 })).toEqual({ error: "Media Tools can't read .docx files. Choose audio, video, or a PDF." });
    expect('error' in classifyFile({ name: 'big.pdf', size: 51 * 1024 * 1024 })).toBe(true);
    expect('error' in classifyFile({ name: 'huge.wav', size: 2049 * 1024 * 1024 })).toBe(true);
  });

  it('names recordings by local time in the shape the server retitles', () => {
    const at = new Date(2026, 10, 5, 9, 12, 30).getTime();
    expect(recordingFileName('audio/mp4;codecs=mp4a.40.2', at)).toBe('Recording 2026-11-05 09.12.m4a');
    expect(recordingFileName('audio/webm;codecs=opus', at)).toBe('Recording 2026-11-05 09.12.webm');
    // The server's TestGeneratedNamesCoverEveryClientAndLocale pins this exact format.
  });

  it('accepts web links only', () => {
    expect(looksLikeURL('https://www.youtube.com/watch?v=abc')).toBe(true);
    expect(looksLikeURL(' youtube.com/watch?v=abc ')).toBe(false);
    expect(looksLikeURL('javascript:alert(1)')).toBe(false);
  });
});
