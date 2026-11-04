import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('./api', () => ({
  completeAudioUpload: vi.fn(),
  createTranscript: vi.fn(),
  extractPDF: vi.fn(),
  presignAudioUpload: vi.fn(),
  transcribeAudio: vi.fn(),
  uploadAudioToPresignedUrl: vi.fn(),
}));

import * as api from './api';
import { isAbortError, uploadAudio } from './mediaUpload';

const file = new File(['audio'], 'Recording 2026-11-05 09.12.webm', { type: 'audio/webm' });
const abort = () => new DOMException('The upload was cancelled.', 'AbortError');

describe('leaving mid-upload', () => {
  beforeEach(() => vi.resetAllMocks());

  it('stops outright instead of falling back to a second upload through the API', async () => {
    const controller = new AbortController();
    vi.mocked(api.presignAudioUpload).mockResolvedValue({ upload_url: 'https://storage.test/x', object_key: 'k' } as never);
    vi.mocked(api.uploadAudioToPresignedUrl).mockImplementation(async () => { controller.abort(); throw abort(); });
    await expect(uploadAudio(file, undefined, controller.signal)).rejects.toSatisfy(isAbortError);
    expect(api.transcribeAudio).not.toHaveBeenCalled();
    expect(api.completeAudioUpload).not.toHaveBeenCalled();
  });

  it('hands the signal to every request in the direct path', async () => {
    const controller = new AbortController();
    vi.mocked(api.presignAudioUpload).mockResolvedValue({ upload_url: 'https://storage.test/x', object_key: 'k' } as never);
    vi.mocked(api.uploadAudioToPresignedUrl).mockResolvedValue(undefined);
    vi.mocked(api.completeAudioUpload).mockResolvedValue({ id: 'a1' } as never);
    await uploadAudio(file, undefined, controller.signal);
    expect(vi.mocked(api.presignAudioUpload).mock.calls[0][1]).toBe(controller.signal);
    expect(vi.mocked(api.uploadAudioToPresignedUrl).mock.calls[0][2]).toMatchObject({ signal: controller.signal });
    expect(vi.mocked(api.completeAudioUpload).mock.calls[0][1]).toBe(controller.signal);
  });

  it('still falls back to the API when storage fails for a real reason', async () => {
    vi.mocked(api.presignAudioUpload).mockRejectedValue(new Error('storage down'));
    vi.mocked(api.transcribeAudio).mockResolvedValue({ id: 'a2' } as never);
    await expect(uploadAudio(file)).resolves.toMatchObject({ id: 'a2' });
  });
});
