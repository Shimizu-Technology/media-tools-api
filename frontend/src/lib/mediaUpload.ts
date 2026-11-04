import {
  completeAudioUpload,
  createTranscript,
  extractPDF,
  presignAudioUpload,
  transcribeAudio,
  uploadAudioToPresignedUrl,
  type AudioTranscription,
} from './api';
import { notifyLibraryActivityChanged } from './libraryActivityEvents';

export const AUDIO_EXTENSIONS = ['.mp3', '.wav', '.caf', '.m4a', '.mp4', '.mov', '.qta', '.aac', '.ogg', '.flac', '.webm'];
export const MAX_AUDIO_MB = 2048;
export const MAX_PDF_MB = 50;

export type FileKind = 'audio' | 'pdf';

function extension(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot >= 0 ? name.slice(dot).toLowerCase() : '';
}

/** Which pipeline a chosen file belongs to, or why it cannot be added. */
export function classifyFile(file: Pick<File, 'name' | 'size'>): { kind: FileKind } | { error: string } {
  const ext = extension(file.name);
  if (ext === '.pdf') {
    return file.size > MAX_PDF_MB * 1024 * 1024 ? { error: `That PDF is ${(file.size / 1048576).toFixed(0)} MB. The limit is ${MAX_PDF_MB} MB.` } : { kind: 'pdf' };
  }
  if (AUDIO_EXTENSIONS.includes(ext)) {
    return file.size > MAX_AUDIO_MB * 1024 * 1024 ? { error: `That file is ${(file.size / 1073741824).toFixed(1)} GB. The limit is 2 GB.` } : { kind: 'audio' };
  }
  return { error: `Media Tools can't read ${ext ? `${ext} files` : 'that file'}. Choose audio, video, or a PDF.` };
}

/**
 * "Recording 2026-11-05 09.12.m4a", in local time. The server treats this
 * shape as a generated name and replaces it with a real title once the
 * transcript is ready; a name the person chose is never replaced.
 */
export function recordingFileName(mimeType: string, createdAt: number): string {
  const date = new Date(createdAt);
  const pad = (value: number) => String(value).padStart(2, '0');
  const stamp = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}.${pad(date.getMinutes())}`;
  const normalized = mimeType.toLowerCase();
  const ext = normalized.includes('mp4') || normalized.includes('m4a') ? 'm4a' : normalized.includes('ogg') ? 'ogg' : 'webm';
  return `Recording ${stamp}.${ext}`;
}

/**
 * Straight to storage with a presigned URL when the server offers one, and
 * through the API otherwise. Progress covers the direct path only.
 */
export async function uploadAudio(file: File, onProgress?: (percent: number) => void): Promise<AudioTranscription> {
  let transcription: AudioTranscription;
  try {
    const presign = await presignAudioUpload(file);
    await uploadAudioToPresignedUrl(presign.upload_url, file, { onProgress });
    transcription = await completeAudioUpload({ object_key: presign.object_key, original_name: file.name, size_bytes: file.size });
  } catch {
    onProgress?.(-1);
    transcription = await transcribeAudio(file);
  }
  notifyLibraryActivityChanged();
  return transcription;
}

export async function addPDF(file: File) {
  const extraction = await extractPDF(file);
  notifyLibraryActivityChanged();
  return extraction;
}

export async function addVideoLink(url: string) {
  const transcript = await createTranscript(url.trim());
  notifyLibraryActivityChanged();
  return transcript;
}

/** Loose check before sending: the server decides what it can extract. */
export function looksLikeURL(value: string): boolean {
  try {
    const url = new URL(value.trim());
    return url.protocol === 'https:' || url.protocol === 'http:';
  } catch {
    return false;
  }
}
